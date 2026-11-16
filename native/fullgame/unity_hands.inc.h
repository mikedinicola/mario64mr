/* Your hands reaching into the game, touching its objects. Included after unity_room.inc.h (in surface_load.c), whose
 * hand triangles (sm64unity_game_hands, game coordinates) it reads, with the hands' joints if the host sends them
 * (sm64unity_game_hand_points: fingertips, which the triangles leave out). There is no grip, only touch.
 *
 * - Touch to collect: a coin, cap or 1-up your hand touches is collected as if Mario had touched it (it is put on
 *   his list of things he collided with this frame, which the game's own interactions then handle). Not stars or
 *   keys: those are Mario's to reach.
 * - Carry on your palm: an enemy or NPC standing on your hand moves with it (and turns with it), as the game moves
 *   things on its platforms. Tip your hand and it falls off; its own physics do the rest.
 * - Squash with your palm: a hand slapped down onto a Goomba (or anything Mario can stomp) from above squashes it, as
 *   Mario's stomp does: it is attacked from above, and its own code does the rest (flattened, its coin dropped).
 * - Pinch to pick up: the host grabs the enemy or NPC nearest a pinch (sm64unity_object_grab), holds it at the pinch
 *   (sm64unity_object_hold) and lets go of it, thrown with the hand (sm64unity_object_release).
 *
 * Bosses, racers and others with scripted paths are left alone, as are platforms, poles and anything Mario holds.
 * UNITY_HANDS_TOUCH and UNITY_HANDS_CARRY turn each off. */
#include "game/interaction.h"
#include "engine/math_util.h"

#define UNITY_HANDS_TOUCH 1
#define UNITY_HANDS_CARRY 1

extern int unity_mario_carried(void);
/* (unity_room_objects.inc.h: enemies and NPCs carried out into the room) */
int unity_object_in_room(struct Object *o);
static int unity_room_object_bring_in(struct Object *o, const float p[3]);
static float unity_held_from[3];

/* The hands' joints (game coordinates): what touches, besides the triangles. Through the window, or anywhere over a
 * diorama, which has no triangles (and where a coin is a few millimetres across). Each touches within `radius` game
 * units of it: as far as a centimetre or so is in the room, at the level's scale there */
#define UNITY_HAND_POINTS 64
static float unity_game_hand_points[UNITY_HAND_POINTS * 3];
static int unity_game_hand_point_count;
static float unity_game_hand_point_radius = 20.f;
EXPORT int sm64unity_game_hand_points(const float *points, int count, float radius) {
    if (count < 0 || (count && !points)) return -1;
    unity_game_hand_point_radius = isfinite(radius) && radius > 0 ? radius : 20.f;
    if (count > UNITY_HAND_POINTS) count = UNITY_HAND_POINTS;
    int kept = 0;
    for (int i = 0; i < count; i++) {
        const float *p = points + i * 3;
        if (!isfinite(p[0]) || !isfinite(p[1]) || !isfinite(p[2])) continue;
        vec3f_copy(&unity_game_hand_points[kept++ * 3], (float *) p);
    }
    unity_game_hand_point_count = kept;
    return kept;
}

#define UNITY_MAX_RIDERS 32
struct UnityRider {
    struct Object *obj;
    const BehaviorScript *behavior; /* (the slot reused by another object: not the same rider) */
    float corners[9]; /* the triangle it stood on: found again next frame by its corners (the host's triangles come
                       * and go as the hand crosses the window's edge, so their order is no guide) */
    float u, v;       /* where it stands on its triangle, in the triangle's own terms */
};
static struct UnityRider unity_riders[UNITY_MAX_RIDERS];
static struct Object *unity_held_obj; /* (pinched: see the end) */
static int unity_rider_count;

static void unity_hand_vertex(const s16 *triangles, int triangle, int corner, float out[3]) {
    const s16 *v = triangles + triangle * 9 + corner * 3;
    out[0] = v[0]; out[1] = v[1]; out[2] = v[2];
}

/* A point on a triangle (its nine corner coordinates) from its two barycentric weights (on b and on c) */
static void unity_corners_point(const float *t, float u, float v, float out[3]) {
    for (int i = 0; i < 3; i++) out[i] = t[i] + u * (t[3 + i] - t[i]) + v * (t[6 + i] - t[i]);
}

/* Is it a floor (as read_surface_data decides, from its winding), and over it, where on it (u, v) and how high? */
static int unity_hand_floor_under(const s16 *triangles, int triangle, float x, float z, float *u, float *v, float *height) {
    float a[3], b[3], c[3];
    unity_hand_vertex(triangles, triangle, 0, a);
    unity_hand_vertex(triangles, triangle, 1, b);
    unity_hand_vertex(triangles, triangle, 2, c);
    float nx = (b[1] - a[1]) * (c[2] - b[2]) - (b[2] - a[2]) * (c[1] - b[1]);
    float ny = (b[2] - a[2]) * (c[0] - b[0]) - (b[0] - a[0]) * (c[2] - b[2]);
    float nz = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    float n = sqrtf(nx * nx + ny * ny + nz * nz);
    if (n < 1e-3f || ny / n <= 0.01f) return 0;
    /* barycentric in the flat (x, z) plane */
    float e1x = b[0] - a[0], e1z = b[2] - a[2], e2x = c[0] - a[0], e2z = c[2] - a[2];
    float det = e1x * e2z - e2x * e1z;
    if (fabsf(det) < 1e-3f) return 0;
    float px = x - a[0], pz = z - a[2];
    float uu = (px * e2z - e2x * pz) / det;
    float vv = (e1x * pz - px * e1z) / det;
    if (uu < 0 || vv < 0 || uu + vv > 1) return 0;
    *u = uu; *v = vv;
    *height = a[1] + uu * (b[1] - a[1]) + vv * (c[1] - a[1]);
    return 1;
}

/* The closest point on a triangle to p (Ericson, Real-Time Collision Detection 5.1.5) */
static void unity_closest_on_triangle(const float p[3], const float a[3], const float b[3], const float c[3], float out[3]) {
    float ab[3], ac[3], ap[3], bp[3], cp[3];
    for (int i = 0; i < 3; i++) { ab[i] = b[i] - a[i]; ac[i] = c[i] - a[i]; ap[i] = p[i] - a[i]; }
#define UDOT(x, y) ((x)[0] * (y)[0] + (x)[1] * (y)[1] + (x)[2] * (y)[2])
    float d1 = UDOT(ab, ap), d2 = UDOT(ac, ap);
    if (d1 <= 0 && d2 <= 0) { vec3f_copy(out, (float *) a); return; }
    for (int i = 0; i < 3; i++) bp[i] = p[i] - b[i];
    float d3 = UDOT(ab, bp), d4 = UDOT(ac, bp);
    if (d3 >= 0 && d4 <= d3) { vec3f_copy(out, (float *) b); return; }
    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0 && d1 >= 0 && d3 <= 0) {
        float t = d1 / (d1 - d3);
        for (int i = 0; i < 3; i++) out[i] = a[i] + t * ab[i];
        return;
    }
    for (int i = 0; i < 3; i++) cp[i] = p[i] - c[i];
    float d5 = UDOT(ab, cp), d6 = UDOT(ac, cp);
    if (d6 >= 0 && d5 <= d6) { vec3f_copy(out, (float *) c); return; }
    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0 && d2 >= 0 && d6 <= 0) {
        float t = d2 / (d2 - d6);
        for (int i = 0; i < 3; i++) out[i] = a[i] + t * ac[i];
        return;
    }
    float va = d3 * d6 - d5 * d4;
    if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0) {
        float t = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        for (int i = 0; i < 3; i++) out[i] = b[i] + t * (c[i] - b[i]);
        return;
    }
    float denom = 1.f / (va + vb + vc);
    float v = vb * denom, w = vc * denom;
    for (int i = 0; i < 3; i++) out[i] = a[i] + ab[i] * v + ac[i] * w;
#undef UDOT
}

static int unity_object_usable(struct Object *o) {
    /* (far from Mario is fine: it's out of sight unless a diorama draws it, and moves all the same. Out in the room it
     * isn't the level's: nothing in the game touches, squashes, carries or picks it up there) */
    return o != gMarioObject && !unity_object_in_room(o) && (o->activeFlags & ACTIVE_FLAG_ACTIVE)
        && (o->header.gfx.node.flags & GRAPH_RENDER_ACTIVE) && !(o->header.gfx.node.flags & GRAPH_RENDER_INVISIBLE);
}

/* The hands' bounds this frame, to pass over objects nowhere near them */
static float unity_hand_min[3], unity_hand_max[3];
static int unity_hand_bounds(void) {
    if (unity_game_hand_count <= 0 && unity_game_hand_point_count <= 0) return 0;
    for (int i = 0; i < 3; i++) { unity_hand_min[i] = 1e9f; unity_hand_max[i] = -1e9f; }
    for (int i = 0; i < unity_game_hand_count * 3; i++) {
        const s16 *v = unity_game_hand_triangles + i * 3;
        for (int j = 0; j < 3; j++) {
            if (v[j] < unity_hand_min[j]) unity_hand_min[j] = v[j];
            if (v[j] > unity_hand_max[j]) unity_hand_max[j] = v[j];
        }
    }
    for (int i = 0; i < unity_game_hand_point_count; i++) {
        const float *v = &unity_game_hand_points[i * 3];
        for (int j = 0; j < 3; j++) {
            if (v[j] < unity_hand_min[j]) unity_hand_min[j] = v[j];
            if (v[j] > unity_hand_max[j]) unity_hand_max[j] = v[j];
        }
    }
    return 1;
}
static int unity_near_hands(struct Object *o, float margin) {
    float bottom = o->oPosY - o->hitboxDownOffset, top = bottom + o->hitboxHeight;
    return o->oPosX + margin >= unity_hand_min[0] && o->oPosX - margin <= unity_hand_max[0]
        && o->oPosZ + margin >= unity_hand_min[2] && o->oPosZ - margin <= unity_hand_max[2]
        && top + margin >= unity_hand_min[1] && bottom - margin <= unity_hand_max[1];
}

/* ---- Touch to collect ---- */

static int unity_is_1up(struct Object *o) {
    const BehaviorScript *b = o->behavior;
    return b == segmented_to_virtual(bhv1Up) || b == segmented_to_virtual(bhv1upWalking)
        || b == segmented_to_virtual(bhv1upRunningAway) || b == segmented_to_virtual(bhv1upSliding)
        || b == segmented_to_virtual(bhv1upJumpOnApproach) || b == segmented_to_virtual(bhvHidden1up)
        || b == segmented_to_virtual(bhvHidden1upInPole);
}
static int unity_collectable(struct Object *o) {
    if (o->oIntangibleTimer != 0 || (o->oInteractStatus & INT_STATUS_INTERACTED)) return 0;
    if (o->oInteractType & (INTERACT_COIN | INTERACT_CAP)) return 1;
    return unity_is_1up(o);
}

static int unity_hand_touches(struct Object *o) {
    float radius = o->hitboxRadius > 40.f ? o->hitboxRadius : 40.f;
    float height = o->hitboxHeight > 40.f ? o->hitboxHeight : 40.f;
    float bottom = o->oPosY - o->hitboxDownOffset, top = bottom + height;
    float centre[3] = { o->oPosX, (bottom + top) * 0.5f, o->oPosZ };
    for (int i = 0; i < unity_game_hand_point_count; i++) {
        const float *p = &unity_game_hand_points[i * 3];
        float dx = p[0] - centre[0], dz = p[2] - centre[2], margin = unity_game_hand_point_radius, reach = radius + margin;
        if (dx * dx + dz * dz <= reach * reach && p[1] >= bottom - margin && p[1] <= top + margin) return 1;
    }
    for (int i = 0; i < unity_game_hand_count; i++) {
        float a[3], b[3], c[3], p[3];
        unity_hand_vertex(unity_game_hand_triangles, i, 0, a);
        unity_hand_vertex(unity_game_hand_triangles, i, 1, b);
        unity_hand_vertex(unity_game_hand_triangles, i, 2, c);
        unity_closest_on_triangle(centre, a, b, c, p);
        float dx = p[0] - centre[0], dz = p[2] - centre[2];
        if (dx * dx + dz * dz <= radius * radius && p[1] >= bottom - 10.f && p[1] <= top + 10.f) return 1;
    }
    return 0;
}

/* ---- Squash with your palm ---- */

/* The hands' triangles last frame, to tell how fast each part of them is coming down */
static s16 unity_last_hand_triangles[UNITY_HAND_SURFACES*9];
static int unity_last_hand_count;
/* ...and their joints (sm64unity_game_hand_points), which come through the window without the whole palm */
static float unity_last_hand_points[UNITY_HAND_POINTS * 3];
static int unity_last_hand_point_count;
static void unity_hands_remember(void) {
    unity_last_hand_point_count = unity_game_hand_point_count;
    memcpy(unity_last_hand_points, unity_game_hand_points, unity_game_hand_point_count * 3 * sizeof(float));
    unity_last_hand_count = unity_game_hand_count;
    if (unity_game_hand_count > 0)
        memcpy(unity_last_hand_triangles, unity_game_hand_triangles, unity_game_hand_count * 9 * sizeof(s16));
}

#define UNITY_SLAP_SPEED 12.f /* game units a frame, down: a slap, not a hand lowered gently onto it (which it climbs) */
/* How far a part of a hand can have gone in a frame and still be found again: a slap covers a few hundred units, and
 * can go right through something (and the ground under it) between two frames */
#define UNITY_SLAP_TRAVEL 800.f
/* Came down through its top between last frame and this one, fast enough? */
static int unity_slap_through(float then, float now, float top) {
    return then >= top - 10.f && now <= top && then - now >= UNITY_SLAP_SPEED && then - now <= UNITY_SLAP_TRAVEL;
}
static int unity_stompable(struct Object *o) {
    return (o->oInteractType & (INTERACT_BOUNCE_TOP | INTERACT_BOUNCE_TOP2 | INTERACT_KOOPA))
        && o->oIntangibleTimer == 0 && !(o->oInteractStatus & INT_STATUS_INTERACTED) && o != unity_held_obj;
}

/* Where a point of a hand triangle (at u, v on it) was last frame: on the triangle then nearest it. 0 if none was */
static int unity_last_point(const s16 *now, float u, float v, float out[3]) {
    int was = -1;
    float nearest = UNITY_SLAP_TRAVEL;
    for (int k = 0; k < unity_last_hand_count; k++) {
        const s16 *l = unity_last_hand_triangles + k * 9;
        float d = 0;
        for (int i = 0; i < 9; i++) d += (float) (now[i] - l[i]) * (now[i] - l[i]);
        d = sqrtf(d / 3);
        if (d < nearest) { nearest = d; was = k; }
    }
    if (was < 0) return 0;
    float last[9];
    for (int i = 0; i < 9; i++) last[i] = unity_last_hand_triangles[was * 9 + i];
    unity_corners_point(last, u, v, out);
    return 1;
}

/* Does a part of a hand over it come down through its top this frame, fast? */
static int unity_hand_slaps(struct Object *o) {
    float radius = o->hitboxRadius > 40.f ? o->hitboxRadius : 40.f;
    float height = o->hitboxHeight > 40.f ? o->hitboxHeight : 40.f;
    float top = o->oPosY - o->hitboxDownOffset + height;
    /* its middle and round its edge, under the palm */
    float spots[5][2] = { { 0, 0 }, { 0.6f, 0 }, { -0.6f, 0 }, { 0, 0.6f }, { 0, -0.6f } };
    for (int t = 0; t < unity_game_hand_count; t++) {
        for (int s = 0; s < 5; s++) {
            float u, v, h, then[3];
            float x = o->oPosX + spots[s][0] * radius, z = o->oPosZ + spots[s][1] * radius;
            if (!unity_hand_floor_under(unity_game_hand_triangles, t, x, z, &u, &v, &h)) continue;
            if (!unity_last_point(unity_game_hand_triangles + t * 9, u, v, then)) continue;
            if (unity_slap_through(then[1], h, top)) return 1;
        }
    }
    /* a joint (a fingertip, a knuckle) over it, come down through its top: the nearest joint last frame is where
     * this part of the hand was (the joints come and go as the hand crosses the window's edge, their order with them) */
    for (int i = 0; i < unity_game_hand_point_count; i++) {
        const float *p = &unity_game_hand_points[i * 3];
        float dx = p[0] - o->oPosX, dz = p[2] - o->oPosZ;
        if (dx * dx + dz * dz > (radius + 20.f) * (radius + 20.f)) continue;
        const float *then = NULL;
        float nearest = UNITY_SLAP_TRAVEL * UNITY_SLAP_TRAVEL;
        for (int k = 0; k < unity_last_hand_point_count; k++) {
            const float *l = &unity_last_hand_points[k * 3];
            float d = (p[0] - l[0]) * (p[0] - l[0]) + (p[1] - l[1]) * (p[1] - l[1]) + (p[2] - l[2]) * (p[2] - l[2]);
            if (d < nearest) { nearest = d; then = l; }
        }
        if (then && unity_slap_through(then[1], p[1], top)) return 1;
    }
    return 0;
}

void unity_hands_squash(void) {
    if ((gTimeStopState & TIME_STOP_ACTIVE) || unity_room_depth || !unity_hand_bounds()) return;
    if (unity_last_hand_count <= 0 && unity_last_hand_point_count <= 0) return;
    static const int lists[] = { OBJ_LIST_PUSHABLE, OBJ_LIST_GENACTOR, OBJ_LIST_DESTRUCTIVE, OBJ_LIST_DEFAULT };
    for (int l = 0; l < (int) (sizeof(lists) / sizeof(lists[0])); l++) {
        struct ObjectNode *head = &gObjectLists[lists[l]];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node;
            /* (a slap can have gone right past it, below it, by now) */
            if (!unity_object_usable(o) || !unity_stompable(o) || !unity_near_hands(o, UNITY_SLAP_TRAVEL)) continue;
            if (!unity_hand_slaps(o)) continue;
            /* as Mario's stomp (interaction.c, attack_object with INT_HIT_FROM_ABOVE) */
            o->oInteractStatus = ATTACK_FROM_ABOVE + (INT_STATUS_INTERACTED | INT_STATUS_WAS_ATTACKED);
        }
    }
}

/* After detect_object_collisions: what your hand touches, Mario touches, so his interactions (or a 1-up's own
 * check for him) collect it this frame */
void unity_hands_touch(void) {
    unity_hands_squash();
    if (!UNITY_HANDS_TOUCH || !gMarioObject || unity_mario_carried() || unity_room_depth) return;
    if ((gTimeStopState & TIME_STOP_ACTIVE) || !unity_hand_bounds()) return;
    static const int lists[] = { OBJ_LIST_LEVEL, OBJ_LIST_GENACTOR, OBJ_LIST_DEFAULT };
    for (int l = 0; l < (int) (sizeof(lists) / sizeof(lists[0])); l++) {
        struct ObjectNode *head = &gObjectLists[lists[l]];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node;
            if (gMarioObject->numCollidedObjs >= 4) return;
            if (!unity_object_usable(o) || !unity_collectable(o) || !unity_near_hands(o, 80.f + unity_game_hand_point_radius)) continue;
            if (obj_check_if_collided_with_object(o, gMarioObject) || o->numCollidedObjs >= 4) continue;
            if (!unity_hand_touches(o)) continue;
            gMarioObject->collidedObjs[gMarioObject->numCollidedObjs++] = o;
            o->collidedObjs[o->numCollidedObjs++] = gMarioObject;
            gMarioObject->collidedObjInteractTypes |= o->oInteractType;
            o->collidedObjInteractTypes |= gMarioObject->oInteractType;
        }
    }
}

/* ---- Carry on your palm ---- */

static int unity_carryable(struct Object *o) {
    if (o == unity_held_obj || o->collisionData || o->oHeldState != HELD_FREE) return 0;
    const BehaviorScript *b = o->behavior;
#define UNITY_IS(bhv) (b == segmented_to_virtual(bhv))
    /* bosses, racers, and things on rails or scripts that a move would break */
    if (UNITY_IS(bhvBowser) || UNITY_IS(bhvKingBobomb) || UNITY_IS(bhvWhompKingBoss) || UNITY_IS(bhvEyerokBoss)
        || UNITY_IS(bhvEyerokHand) || UNITY_IS(bhvWigglerHead) || UNITY_IS(bhvWigglerBody) || UNITY_IS(bhvBigBully)
        || UNITY_IS(bhvBigBullyWithMinions) || UNITY_IS(bhvBigChillBully) || UNITY_IS(bhvRacingPenguin)
        || UNITY_IS(bhvGhostHuntBigBoo) || UNITY_IS(bhvBalconyBigBoo) || UNITY_IS(bhvMerryGoRoundBigBoo)
        || UNITY_IS(bhvDorrie) || UNITY_IS(bhvUnagi) || UNITY_IS(bhvSushiShark) || UNITY_IS(bhvMantaRay)
        || UNITY_IS(bhvKlepto) || UNITY_IS(bhvBeginningLakitu) || UNITY_IS(bhvCameraLakitu) || UNITY_IS(bhvEndToad)
        || UNITY_IS(bhvThwomp) || UNITY_IS(bhvThwomp2) || UNITY_IS(bhvPiranhaPlant) || UNITY_IS(bhvFirePiranhaPlant))
        return 0;
    if (UNITY_IS(bhvKoopa) && (o->oBehParams2ndByte == KOOPA_BP_KOOPA_THE_QUICK_BOB
                               || o->oBehParams2ndByte == KOOPA_BP_KOOPA_THE_QUICK_THI))
        return 0;
#undef UNITY_IS
    return 1;
}

/* How far apart two triangles' corners are, on average */
static float unity_corner_distance(const float *t, const s16 *n) {
    float d = 0;
    for (int i = 0; i < 9; i++) d += (t[i] - n[i]) * (t[i] - n[i]);
    return sqrtf(d / 3);
}

/* At the start of the frame, with the hands where they are now: everything that stood on them last frame goes where
 * its place on its triangle has gone (the triangle now nearest the one it stood on), and turns as it turned */
void unity_hands_place_held(void);
void unity_hands_carry_riders(void) {
    unity_hands_place_held();
    int count = unity_rider_count;
    unity_rider_count = 0;
    if (!UNITY_HANDS_CARRY || count == 0 || unity_game_hand_count == 0) return;
    for (int i = 0; i < count; i++) {
        struct UnityRider *r = &unity_riders[i];
        struct Object *o = r->obj;
        if (o->behavior != r->behavior || !unity_object_usable(o) || o->oHeldState != HELD_FREE) continue;
        int best = -1;
        float bestDistance = 400.f; /* (further: a different triangle, or a jump, not a carry) */
        for (int t = 0; t < unity_game_hand_count; t++) {
            float d = unity_corner_distance(r->corners, unity_game_hand_triangles + t * 9);
            if (d < bestDistance) { bestDistance = d; best = t; }
        }
        if (best < 0) continue;
        float now[9];
        for (int k = 0; k < 9; k++) now[k] = unity_game_hand_triangles[best * 9 + k];
        float was[3], at[3];
        unity_corners_point(r->corners, r->u, r->v, was);
        unity_corners_point(now, r->u, r->v, at);
        o->oPosX += at[0] - was[0]; o->oPosY += at[1] - was[1]; o->oPosZ += at[2] - was[2];
        float x0 = r->corners[3] - r->corners[0], z0 = r->corners[5] - r->corners[2];
        float x1 = now[3] - now[0], z1 = now[5] - now[2];
        if (x0 * x0 + z0 * z0 > 1.f && x1 * x1 + z1 * z1 > 1.f) {
            s16 turn = atan2s(z1, x1) - atan2s(z0, x0);
            o->oFaceAngleYaw += turn; o->oMoveAngleYaw += turn;
        }
    }
}

/* At the end of the frame, after every object has moved: what is standing on a hand now. A palm come up into
 * something from below (by up to 100 units this frame, more than the game's own floors catch) scoops it up */
static void unity_hands_find_riders_now(void);
void unity_hands_find_riders(void) {
    unity_hands_place_held();
    unity_hands_find_riders_now();
    unity_hands_remember(); /* (for next frame: slaps, and scoops) */
}
static void unity_hands_find_riders_now(void) {
    unity_rider_count = 0;
    if (!UNITY_HANDS_CARRY || (gTimeStopState & TIME_STOP_ACTIVE) || unity_room_depth || unity_game_hand_count <= 0
        || !unity_hand_bounds()) return;
    static const int lists[] = { OBJ_LIST_PUSHABLE, OBJ_LIST_GENACTOR, OBJ_LIST_DESTRUCTIVE, OBJ_LIST_LEVEL, OBJ_LIST_DEFAULT };
    for (int l = 0; l < (int) (sizeof(lists) / sizeof(lists[0])); l++) {
        struct ObjectNode *head = &gObjectLists[lists[l]];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node;
            if (unity_rider_count >= UNITY_MAX_RIDERS) return;
            if (!unity_object_usable(o) || !unity_near_hands(o, 100.f) || !unity_carryable(o)) continue;
            int best = -1;
            float bestGap = 1e9f, bestU = 0, bestV = 0, bestHeight = 0;
            for (int t = 0; t < unity_game_hand_count; t++) {
                float u, v, height;
                if (!unity_hand_floor_under(unity_game_hand_triangles, t, o->oPosX, o->oPosZ, &u, &v, &height)) continue;
                float gap = o->oPosY - height; /* standing on it: at it, just over it, or the palm come up into it */
                if (gap < -100.f || gap > 30.f || fabsf(gap) >= fabsf(bestGap)) continue;
                if (gap < 0) { /* into it: only scooped by a palm coming up (one come down onto it squashes it) */
                    float then[3];
                    if (!unity_last_point(unity_game_hand_triangles + t * 9, u, v, then) || then[1] >= height) continue;
                }
                best = t; bestGap = gap; bestU = u; bestV = v; bestHeight = height;
            }
            if (best < 0) continue;
            if (bestGap < 0) o->oPosY = bestHeight; /* (on top of it, not inside it) */
            struct UnityRider *r = &unity_riders[unity_rider_count++];
            r->obj = o; r->behavior = o->behavior; r->u = bestU; r->v = bestV;
            for (int k = 0; k < 9; k++) r->corners[k] = unity_game_hand_triangles[best * 9 + k];
        }
    }
}

/* ---- Pinch to pick up ---- */

static const BehaviorScript *unity_held_behavior;
static float unity_held_offset[3], unity_held_at[3]; /* (where it is from the pinch, as it was grabbed) */
static s16 unity_held_level, unity_held_area;

/* Still there to hold? (killed, collected, unloaded, or another level: let go of) */
static int unity_still_held(void) {
    struct Object *o = unity_held_obj;
    if (!o) return 0;
    if (o->behavior != unity_held_behavior || !(o->activeFlags & ACTIVE_FLAG_ACTIVE) || o->oHeldState != HELD_FREE
        || gCurrLevelNum != unity_held_level || gCurrAreaIndex != unity_held_area) {
        unity_held_obj = NULL;
        return 0;
    }
    return 1;
}

/* How far a pinch is outside an object's hitbox (a cylinder) */
static float unity_pinch_distance(struct Object *o, float x, float y, float z) {
    float radius = o->hitboxRadius > 40.f ? o->hitboxRadius : 40.f;
    float height = o->hitboxHeight > 40.f ? o->hitboxHeight : 40.f;
    float bottom = o->oPosY - o->hitboxDownOffset, top = bottom + height;
    float dx = x - o->oPosX, dz = z - o->oPosZ;
    float across = sqrtf(dx * dx + dz * dz) - radius;
    float up = y < bottom ? bottom - y : y > top ? y - top : 0;
    if (across < 0) across = 0;
    return sqrtf(across * across + up * up);
}
static void unity_hold(struct Object *o, float x, float y, float z) {
    unity_held_obj = o; unity_held_behavior = o->behavior;
    unity_held_level = gCurrLevelNum; unity_held_area = gCurrAreaIndex;
    unity_held_offset[0] = o->oPosX - x; unity_held_offset[1] = o->oPosY - y; unity_held_offset[2] = o->oPosZ - z;
    unity_held_at[0] = x; unity_held_at[1] = y; unity_held_at[2] = z;
}

/* A pinch at (x, y, z), game coordinates: picks up the enemy or NPC nearest it, its hitbox within reach of it.
 * 1 if it picked one up */
EXPORT int sm64unity_object_grab(float x, float y, float z, float reach) {
    if (!isfinite(x) || !isfinite(y) || !isfinite(z) || !isfinite(reach) || unity_room_depth) return 0;
    if (!gMarioObject || unity_mario_carried() || unity_still_held()) return 0;
    static const int lists[] = { OBJ_LIST_PUSHABLE, OBJ_LIST_GENACTOR, OBJ_LIST_DESTRUCTIVE, OBJ_LIST_DEFAULT };
    struct Object *best = NULL;
    float bestDistance = reach;
    for (int l = 0; l < (int) (sizeof(lists) / sizeof(lists[0])); l++) {
        struct ObjectNode *head = &gObjectLists[lists[l]];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node;
            if (!unity_object_usable(o) || !unity_carryable(o)) continue;
            float distance = unity_pinch_distance(o, x, y, z);
            if (distance <= bestDistance) { bestDistance = distance; best = o; }
        }
    }
    if (!best) return 0;
    unity_hold(best, x, y, z);
    unity_held_from[0] = best->oPosX; unity_held_from[1] = best->oPosY; unity_held_from[2] = best->oPosZ;
    return 1;
}
/* Where the pinch holding it is now, in the game (carried back in through the window, if it was out in the room).
 * 1 while it holds something, 0 once it is gone */
EXPORT int sm64unity_object_hold(float x, float y, float z) {
    if (!unity_still_held()) return 0;
    if (isfinite(x) && isfinite(y) && isfinite(z)) {
        unity_held_at[0] = x; unity_held_at[1] = y; unity_held_at[2] = z;
        if (unity_object_in_room(unity_held_obj)) {
            float p[3] = { x + unity_held_offset[0], y + unity_held_offset[1], z + unity_held_offset[2] };
            unity_room_object_bring_in(unity_held_obj, p);
        }
    }
    return 1;
}
/* Let go of it in the game, moving as the hand was (game units a frame). (Held out in the room, it goes back where it
 * was picked up in the level: sm64unity_object_release_room lets go of it out there) */
EXPORT void sm64unity_object_release(float vx, float vy, float vz) {
    if (!unity_still_held()) return;
    struct Object *o = unity_held_obj;
    unity_held_obj = NULL;
    if (unity_object_in_room(o)) {
        unity_room_object_bring_in(o, unity_held_from);
        return;
    }
    if (!isfinite(vx) || !isfinite(vy) || !isfinite(vz)) return;
    float along = sqrtf(vx * vx + vz * vz);
    o->oVelY = vy > 60.f ? 60.f : vy;
    o->oForwardVel = along > 60.f ? 60.f : along;
    if (along > 1.f) o->oMoveAngleYaw = atan2s(vz, vx);
}

/* It goes where the pinch is, before the objects move and after (whatever its own behaviour did with it): held still
 * in the air, no speed of its own to fall with */
void unity_hands_place_held(void) {
    if (!unity_still_held()) return;
    struct Object *o = unity_held_obj;
    o->oPosX = unity_held_at[0] + unity_held_offset[0];
    o->oPosY = unity_held_at[1] + unity_held_offset[1];
    o->oPosZ = unity_held_at[2] + unity_held_offset[2];
    o->oVelX = o->oVelY = o->oVelZ = 0;
    o->oForwardVel = 0;
    o->header.gfx.pos[0] = o->oPosX; o->header.gfx.pos[1] = o->oPosY; o->header.gfx.pos[2] = o->oPosZ;
}
