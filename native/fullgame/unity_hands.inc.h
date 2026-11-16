/* Your hands reaching into the game, touching its objects. Included after unity_room.inc.h (in surface_load.c), whose
 * hand triangles (sm64unity_game_hands, game coordinates) it reads. Everything here is the game's side alone: the host
 * sends the hands' shape and nothing else, so there is no grip, only touch.
 *
 * - Touch to collect: a coin, cap or 1-up your hand touches is collected as if Mario had touched it (it is put on
 *   his list of things he collided with this frame, which the game's own interactions then handle). Not stars or
 *   keys: those are Mario's to reach.
 * - Carry on your palm: an enemy or NPC standing on your hand moves with it (and turns with it), as the game moves
 *   things on its platforms. Tip your hand and it falls off; its own physics do the rest.
 *
 * Bosses, racers and others with scripted paths are left alone, as are platforms, poles and anything Mario holds.
 * UNITY_HANDS_TOUCH and UNITY_HANDS_CARRY turn each off. */
#include "game/interaction.h"
#include "engine/math_util.h"

#define UNITY_HANDS_TOUCH 1
#define UNITY_HANDS_CARRY 1

extern int unity_mario_carried(void);

/* The hands' triangles last frame, which the riders' places were measured on */
static s16 unity_prev_hand_triangles[UNITY_HAND_SURFACES*9];
static int unity_prev_hand_count;

#define UNITY_MAX_RIDERS 32
struct UnityRider {
    struct Object *obj;
    const BehaviorScript *behavior; /* (the slot reused by another object: not the same rider) */
    int triangle;
    float u, v;   /* where it stands on its triangle, in the triangle's own terms */
    float x, z;   /* the triangle's first edge, flat, for how far the hand turned */
};
static struct UnityRider unity_riders[UNITY_MAX_RIDERS];
static int unity_rider_count;

static void unity_hand_vertex(const s16 *triangles, int triangle, int corner, float out[3]) {
    const s16 *v = triangles + triangle * 9 + corner * 3;
    out[0] = v[0]; out[1] = v[1]; out[2] = v[2];
}

/* A point on a triangle from its two barycentric weights (on b and on c) */
static void unity_hand_point(const s16 *triangles, int triangle, float u, float v, float out[3]) {
    float a[3], b[3], c[3];
    unity_hand_vertex(triangles, triangle, 0, a);
    unity_hand_vertex(triangles, triangle, 1, b);
    unity_hand_vertex(triangles, triangle, 2, c);
    for (int i = 0; i < 3; i++) out[i] = a[i] + u * (b[i] - a[i]) + v * (c[i] - a[i]);
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
    /* (far from Mario is fine: it's out of sight unless a diorama draws it, and moves all the same) */
    return o != gMarioObject && (o->activeFlags & ACTIVE_FLAG_ACTIVE)
        && (o->header.gfx.node.flags & GRAPH_RENDER_ACTIVE) && !(o->header.gfx.node.flags & GRAPH_RENDER_INVISIBLE);
}

/* The hands' bounds this frame, to pass over objects nowhere near them */
static float unity_hand_min[3], unity_hand_max[3];
static int unity_hand_bounds(void) {
    if (unity_game_hand_count <= 0) return 0;
    for (int i = 0; i < 3; i++) { unity_hand_min[i] = 1e9f; unity_hand_max[i] = -1e9f; }
    for (int i = 0; i < unity_game_hand_count * 3; i++) {
        const s16 *v = unity_game_hand_triangles + i * 3;
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

/* After detect_object_collisions: what your hand touches, Mario touches, so his interactions (or a 1-up's own
 * check for him) collect it this frame */
void unity_hands_touch(void) {
    if (!UNITY_HANDS_TOUCH || !gMarioObject || unity_mario_carried() || unity_room_depth) return;
    if ((gTimeStopState & TIME_STOP_ACTIVE) || !unity_hand_bounds()) return;
    static const int lists[] = { OBJ_LIST_LEVEL, OBJ_LIST_GENACTOR, OBJ_LIST_DEFAULT };
    for (int l = 0; l < (int) (sizeof(lists) / sizeof(lists[0])); l++) {
        struct ObjectNode *head = &gObjectLists[lists[l]];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node;
            if (gMarioObject->numCollidedObjs >= 4) return;
            if (!unity_object_usable(o) || !unity_collectable(o) || !unity_near_hands(o, 80.f)) continue;
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
    if (o->collisionData || o->oHeldState != HELD_FREE) return 0;
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

/* At the start of the frame, with the hands where they are now: everything that stood on them last frame goes where
 * its place on its triangle has gone, and turns as far as the triangle turned */
void unity_hands_carry_riders(void) {
    int count = unity_rider_count;
    unity_rider_count = 0;
    if (!UNITY_HANDS_CARRY || count == 0 || unity_game_hand_count != unity_prev_hand_count) return;
    for (int i = 0; i < count; i++) {
        struct UnityRider *r = &unity_riders[i];
        struct Object *o = r->obj;
        if (o->behavior != r->behavior || !unity_object_usable(o) || o->oHeldState != HELD_FREE) continue;
        float was[3], now[3];
        unity_hand_point(unity_prev_hand_triangles, r->triangle, r->u, r->v, was);
        unity_hand_point(unity_game_hand_triangles, r->triangle, r->u, r->v, now);
        float d[3] = { now[0] - was[0], now[1] - was[1], now[2] - was[2] };
        if (!isfinite(d[0]) || !isfinite(d[1]) || !isfinite(d[2])) continue;
        if (d[0] * d[0] + d[1] * d[1] + d[2] * d[2] > 400.f * 400.f) continue; /* a jump, not a carry */
        o->oPosX += d[0]; o->oPosY += d[1]; o->oPosZ += d[2];
        float a[3], b[3];
        unity_hand_vertex(unity_game_hand_triangles, r->triangle, 0, a);
        unity_hand_vertex(unity_game_hand_triangles, r->triangle, 1, b);
        float x = b[0] - a[0], z = b[2] - a[2];
        if (x * x + z * z > 1.f && r->x * r->x + r->z * r->z > 1.f) {
            s16 turn = atan2s(z, x) - atan2s(r->z, r->x);
            o->oFaceAngleYaw += turn; o->oMoveAngleYaw += turn;
        }
    }
}

/* At the end of the frame, after every object has moved: what is standing on a hand now */
void unity_hands_find_riders(void) {
    unity_rider_count = 0;
    unity_prev_hand_count = unity_game_hand_count;
    if (unity_game_hand_count > 0)
        memcpy(unity_prev_hand_triangles, unity_game_hand_triangles, unity_game_hand_count * 9 * sizeof(s16));
    if (!UNITY_HANDS_CARRY || (gTimeStopState & TIME_STOP_ACTIVE) || unity_room_depth || !unity_hand_bounds()) return;
    static const int lists[] = { OBJ_LIST_PUSHABLE, OBJ_LIST_GENACTOR, OBJ_LIST_DESTRUCTIVE, OBJ_LIST_LEVEL, OBJ_LIST_DEFAULT };
    for (int l = 0; l < (int) (sizeof(lists) / sizeof(lists[0])); l++) {
        struct ObjectNode *head = &gObjectLists[lists[l]];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node;
            if (unity_rider_count >= UNITY_MAX_RIDERS) return;
            if (!unity_object_usable(o) || !unity_near_hands(o, 40.f) || !unity_carryable(o)) continue;
            int best = -1;
            float bestGap = 1e9f, bestU = 0, bestV = 0;
            for (int t = 0; t < unity_game_hand_count; t++) {
                float u, v, height;
                if (!unity_hand_floor_under(unity_game_hand_triangles, t, o->oPosX, o->oPosZ, &u, &v, &height)) continue;
                float gap = o->oPosY - height; /* standing on it: at it, or just over it */
                if (gap < -30.f || gap > 30.f || fabsf(gap) >= fabsf(bestGap)) continue;
                best = t; bestGap = gap; bestU = u; bestV = v;
            }
            if (best < 0) continue;
            struct UnityRider *r = &unity_riders[unity_rider_count++];
            r->obj = o; r->behavior = o->behavior; r->triangle = best; r->u = bestU; r->v = bestV;
            float a[3], b[3];
            unity_hand_vertex(unity_game_hand_triangles, best, 0, a);
            unity_hand_vertex(unity_game_hand_triangles, best, 1, b);
            r->x = b[0] - a[0]; r->z = b[2] - a[2];
        }
    }
}
