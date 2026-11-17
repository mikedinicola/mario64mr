/* Enemies and NPCs out in your room (Tier 3). Included after unity_hands.inc.h (in surface_load.c), whose pinch it
 * extends: something picked up with a pinch in the window can be carried out of it, put down on the room's surfaces
 * and live there as Mario does out in the room (unity_mr.c, carry modes 2 and 3).
 *
 * - Out in the room its coordinates are the room's (game units, as Mario's are there): its update runs against the
 *   room's surfaces (unity_room_begin / _end round cur_obj_update, from the object lists' loop: unity_object_update)
 *   and its draws are tagged 4 (5 its shadow, cast on the room) for the host to draw in the room.
 * - The game goes on with it as near and in view (never "far away", which leaves its movement out), and Mario as far
 *   from it, unless he's out in the room too. Its home is where it was put down, and it's nobody's child (a spawner
 *   would unload it for being far from Mario).
 * - It touches only what's out in the room too, Mario if he's out there, and nothing touches it while it's held
 *   (object_collision.c, check_collision_in_list; unity_same_world).
 * - It goes back into the game when it walks through the window (the host's sm64unity_room_object_return), is carried
 *   back in, walks off what the room has scanned, or the level or area changes: back to its own home and spawner.
 *
 * The host (MarioCarrier) carries it in and out: sm64unity_object_hold_room / _release_room in the room's units,
 * sm64unity_object_grab_room to pick one up out there, sm64unity_room_objects for where they are. */

#define UNITY_ROOM_OBJECTS 16 /* (MarioCarrier.roomObjects) */
struct UnityRoomObject {
    struct Object *obj;
    const BehaviorScript *behavior;
    struct Object *parent;                  /* (its spawner, and the spawner's behaviour: still it when it goes back?) */
    const BehaviorScript *parentBehavior;
    float home[3];                          /* its home in the level */
    float from[3];                          /* where in the level it was picked up: back there if it can't stay out */
    s16 level, area;
};
static struct UnityRoomObject unity_room_objects[UNITY_ROOM_OBJECTS];
static int unity_room_object_count;

extern int unity_mario_outside(void);
extern void unity_skip_object_interpolation(struct Object *o);
/* (unity_spawn.inc.h: what came out of the treasure chest) */
int unity_spawned(struct Object *o);
static void unity_spawned_remove(struct Object *o);
static void unity_spawned_frame(void);
static void unity_spawned_adopt(void);
static int unity_spawned_rebehaved(struct Object *o);

static struct UnityRoomObject *unity_room_slot(struct Object *o) {
    if (!o || unity_room_object_count == 0) return NULL;
    for (int i = 0; i < UNITY_ROOM_OBJECTS; i++)
        if (unity_room_objects[i].obj == o) return &unity_room_objects[i];
    return NULL;
}
int unity_object_in_room(struct Object *o) { return unity_room_slot(o) != NULL; }

/* Which world it's in, for what touches what (object_collision.c): 1 the room (out there, or Mario out there), 0 the
 * level; -1 held out in the room, touching nothing */
static int unity_world(struct Object *o) {
    if (unity_room_slot(o)) return o == unity_held_obj ? -1 : 1;
    return o == gMarioObject && unity_mario_outside();
}
int unity_same_world(struct Object *a, struct Object *b) {
    if (unity_room_object_count == 0 && !unity_mario_outside()) return 1;
    int w = unity_world(a);
    return w >= 0 && w == unity_world(b);
}

/* The room's floor under a point (its height), or none */
static int unity_room_floor(float x, float y, float z, float *height) {
    if (unity_room_surface_count() == 0) return 0;
    struct Surface *floor;
    unity_room_begin();
    float h = find_floor(x, y, z, &floor);
    unity_room_end();
    if (height) *height = h;
    return floor != NULL;
}

static void unity_object_place(struct Object *o, const float p[3]) {
    o->oPosX = p[0]; o->oPosY = p[1]; o->oPosZ = p[2];
    vec3f_copy(o->header.gfx.pos, (float *) p);
    unity_skip_object_interpolation(o); /* (from one world into the other: no frame drawn in between) */
}

/* Out of the level and into the room (a slot of its own), or NULL if the room is full */
static struct UnityRoomObject *unity_room_object_take(struct Object *o, const float from[3]) {
    struct UnityRoomObject *r = unity_room_slot(o);
    if (r) return r;
    for (int i = 0; i < UNITY_ROOM_OBJECTS && !r; i++)
        if (!unity_room_objects[i].obj) r = &unity_room_objects[i];
    if (!r) return NULL;
    r->obj = o; r->behavior = o->behavior;
    r->parent = o->parentObj; r->parentBehavior = o->parentObj ? o->parentObj->behavior : NULL;
    r->home[0] = o->oHomeX; r->home[1] = o->oHomeY; r->home[2] = o->oHomeZ;
    vec3f_copy(r->from, (float *) from);
    r->level = gCurrLevelNum; r->area = gCurrAreaIndex;
    o->parentObj = o;
    unity_room_object_count++;
    return r;
}
static void unity_room_object_forget(struct UnityRoomObject *r) {
    if (!r->obj) return;
    r->obj = NULL;
    unity_room_object_count--;
}

/* Back into the level at p (its own home and spawner again), not moving. Something out of the treasure chest, sent
 * back where it came from (r->from, or where the hand took it from), has no place there: it's gone instead */
static void unity_room_object_put_back(struct UnityRoomObject *r, const float p[3]) {
    struct Object *o = r->obj;
    if (!o) return;
    if (unity_spawned(o) && (p == r->from || p == unity_held_from)) {
        unity_room_object_forget(r);
        unity_spawned_remove(o);
        return;
    }
    o->oHomeX = r->home[0]; o->oHomeY = r->home[1]; o->oHomeZ = r->home[2];
    if (r->parent && r->parent != o && (r->parent->activeFlags & ACTIVE_FLAG_ACTIVE) && r->parent->behavior == r->parentBehavior)
        o->parentObj = r->parent;
    unity_object_place(o, p);
    o->oVelX = o->oVelY = o->oVelZ = 0;
    o->oForwardVel = 0;
    o->oFloor = NULL; /* (a room surface: found again in the level on its next step) */
    unity_room_object_forget(r);
}

static int unity_room_object_bring_in(struct Object *o, const float p[3]) {
    struct UnityRoomObject *r = unity_room_slot(o);
    if (!r) return 0;
    unity_room_object_put_back(r, p);
    return 1;
}

/* At the start of the objects' frame: forget what's gone (killed, unloaded), and a level or area changed puts what's
 * out back where it came from */
void unity_room_objects_frame(void) {
    for (int i = 0; i < UNITY_ROOM_OBJECTS; i++) {
        struct UnityRoomObject *r = &unity_room_objects[i];
        if (!r->obj) continue;
        if (r->obj->behavior != r->behavior && unity_spawned_rebehaved(r->obj)) r->behavior = r->obj->behavior;
        if (!(r->obj->activeFlags & ACTIVE_FLAG_ACTIVE) || r->obj->behavior != r->behavior) unity_room_object_forget(r);
        else if (gCurrLevelNum != r->level || gCurrAreaIndex != r->area) unity_room_object_put_back(r, r->from);
    }
    unity_spawned_frame();
}
/* A warp (init_mario_after_warp): the level's objects are new, or back where they were */
void unity_room_objects_warped(void) {
    for (int i = 0; i < UNITY_ROOM_OBJECTS; i++) {
        struct UnityRoomObject *r = &unity_room_objects[i];
        if (!r->obj) continue;
        if ((r->obj->activeFlags & ACTIVE_FLAG_ACTIVE) && r->obj->behavior == r->behavior) unity_room_object_put_back(r, r->from);
        else unity_room_object_forget(r);
    }
    if (unity_held_obj && !unity_still_held()) unity_held_obj = NULL;
}

/* In place of cur_obj_update (object_list_processor.c): an object out in the room updates against the room, as near
 * and in view, with Mario far away (unless he's out there too, in the same coordinates) */
void unity_object_update(void) {
    struct Object *o = gCurrentObject;
    struct UnityRoomObject *r = unity_room_slot(o);
    if (!r) { cur_obj_update(); return; }
    if (o != unity_held_obj && !unity_room_floor(o->oPosX, o->oPosY, o->oPosZ, NULL)) {
        /* (off the edge of what the room has scanned: back into the game, as Mario goes) */
        unity_room_object_put_back(r, r->from);
        if (o->activeFlags & ACTIVE_FLAG_ACTIVE) cur_obj_update();
        return;
    }
    o->activeFlags &= ~(ACTIVE_FLAG_FAR_AWAY | ACTIVE_FLAG_IN_DIFFERENT_ROOM);
    int phantom = gMarioObject && gMarioState && !unity_mario_outside();
    float marioObj[3], mario[3];
    if (phantom) {
        marioObj[0] = gMarioObject->oPosX; marioObj[1] = gMarioObject->oPosY; marioObj[2] = gMarioObject->oPosZ;
        vec3f_copy(mario, gMarioState->pos);
        /* (straight above it, well away: under the 25000 its walks take for "far from home") */
        gMarioObject->oPosX = o->oPosX; gMarioObject->oPosY = o->oPosY + 20000.f; gMarioObject->oPosZ = o->oPosZ;
        gMarioState->pos[0] = gMarioObject->oPosX; gMarioState->pos[1] = gMarioObject->oPosY; gMarioState->pos[2] = gMarioObject->oPosZ;
    }
    unity_room_begin();
    cur_obj_update();
    unity_room_end();
    if (phantom) {
        gMarioObject->oPosX = marioObj[0]; gMarioObject->oPosY = marioObj[1]; gMarioObject->oPosZ = marioObj[2];
        vec3f_copy(gMarioState->pos, mario);
    }
    /* (what it let out, out here with it before its first step: a box's coins, made in the level, would find no
     * floor there and be gone) */
    if (unity_spawned(o)) unity_spawned_adopt();
    if (!(o->activeFlags & ACTIVE_FLAG_ACTIVE)) {
        unity_room_object_forget(r);
        return;
    }
    o->activeFlags &= ~(ACTIVE_FLAG_FAR_AWAY | ACTIVE_FLAG_IN_DIFFERENT_ROOM);
    if (o->oHeldState == HELD_FREE) o->header.gfx.node.flags |= GRAPH_RENDER_ACTIVE;
}

/* Drawing (rendering_graph_node.c): what an object's display lists are tagged, for the host. 1 Mario, 2 his shadow;
 * 4 an object out in the room (or something it spawned, its dust), 5 its shadow. 0 the level */
static int unity_graph_room_object(struct GraphNodeObject *node) {
    if (!node || unity_room_object_count == 0) return 0;
    struct Object *o = (struct Object *) node;
    if (o < gObjectPool || o >= gObjectPool + OBJECT_POOL_CAPACITY) return 0;
    return unity_room_slot(o) || unity_room_slot(o->parentObj);
}
int unity_graph_tag(struct GraphNodeObject *node, int shadow) {
    if (!node) return 0;
    if (gMarioObject && node == &gMarioObject->header.gfx) return shadow ? 2 : 1;
    if (unity_graph_room_object(node)) return shadow ? 5 : 4;
    return 0;
}
/* Its shadow falls on the room's surfaces (Mario's out in the room, or an object's) */
int unity_graph_in_room(struct GraphNodeObject *node) {
    if (!node) return 0;
    if (gMarioObject && node == &gMarioObject->header.gfx) return unity_mario_outside();
    return unity_graph_room_object(node);
}

/* ---- Carried out, put down, picked up, gone back in ---- */

/* Where the pinch holding it is now, out in the room (room game units). 1 while it holds something, 0 once it is gone,
 * -1 if it couldn't go out (no room scanned yet, or the room full): still held, in the game */
EXPORT int sm64unity_object_hold_room(float x, float y, float z) {
    if (!unity_still_held()) return 0;
    struct Object *o = unity_held_obj;
    if (!unity_room_slot(o)) {
        if (unity_room_surface_count() == 0 || !unity_room_object_take(o, unity_held_from)) return -1;
        /* (held by its top, as it hangs from the pinch out there) */
        float height = o->hitboxHeight > 40.f ? o->hitboxHeight : 40.f;
        unity_held_offset[0] = 0; unity_held_offset[1] = -height; unity_held_offset[2] = 0;
        o->activeFlags &= ~(ACTIVE_FLAG_FAR_AWAY | ACTIVE_FLAG_IN_DIFFERENT_ROOM);
        o->header.gfx.node.flags |= GRAPH_RENDER_ACTIVE;
        unity_skip_object_interpolation(o);
    }
    if (isfinite(x) && isfinite(y) && isfinite(z)) { unity_held_at[0] = x; unity_held_at[1] = y; unity_held_at[2] = z; }
    unity_hands_place_held();
    return 1;
}
/* Let go of it out in the room, moving as the hand was (room game units a frame): it lives where it lands, its home
 * the floor under it. 1 if it stays out, 0 if it went back into the game (nothing under it) */
EXPORT int sm64unity_object_release_room(float vx, float vy, float vz) {
    if (!unity_still_held()) return 0;
    struct Object *o = unity_held_obj;
    struct UnityRoomObject *r = unity_room_slot(o);
    if (!r) { sm64unity_object_release(vx, vy, vz); return 0; }
    unity_held_obj = NULL;
    float floor;
    if (!unity_room_floor(o->oPosX, o->oPosY, o->oPosZ, &floor)) {
        unity_room_object_put_back(r, r->from);
        return 0;
    }
    o->oHomeX = o->oPosX; o->oHomeY = floor; o->oHomeZ = o->oPosZ;
    if (!isfinite(vx) || !isfinite(vy) || !isfinite(vz)) vx = vy = vz = 0;
    float along = sqrtf(vx * vx + vz * vz);
    o->oVelY = vy > 60.f ? 60.f : vy;
    o->oForwardVel = along > 60.f ? 60.f : along;
    if (along > 1.f) o->oMoveAngleYaw = atan2s(vz, vx);
    return 1;
}
/* A pinch out in the room (room game units): picks up the object out there nearest it. 1 if it picked one up */
EXPORT int sm64unity_object_grab_room(float x, float y, float z, float reach) {
    if (!isfinite(x) || !isfinite(y) || !isfinite(z) || !isfinite(reach) || unity_room_depth) return 0;
    if (unity_still_held()) return 0;
    struct Object *best = NULL;
    float bestDistance = reach;
    for (int i = 0; i < UNITY_ROOM_OBJECTS; i++) {
        struct Object *o = unity_room_objects[i].obj;
        if (!o || !(o->activeFlags & ACTIVE_FLAG_ACTIVE) || o->oHeldState != HELD_FREE) continue;
        float distance = unity_pinch_distance(o, x, y, z);
        if (distance <= bestDistance) { bestDistance = distance; best = o; }
    }
    if (!best) return 0;
    unity_hold(best, x, y, z);
    vec3f_copy(unity_held_from, unity_room_slot(best)->from);
    return 1;
}
/* The objects out in the room, 8 floats each: its slot, held (1) or not, where it is and how it's moving (room game
 * units, a frame). How many */
EXPORT int sm64unity_room_objects(float *out, int max) {
    if (!out || max <= 0) return 0;
    int n = 0;
    for (int i = 0; i < UNITY_ROOM_OBJECTS && n < max; i++) {
        struct Object *o = unity_room_objects[i].obj;
        if (!o || !(o->activeFlags & ACTIVE_FLAG_ACTIVE)) continue;
        float *v = out + n++ * 8;
        v[0] = i; v[1] = o == unity_held_obj;
        v[2] = o->oPosX; v[3] = o->oPosY; v[4] = o->oPosZ;
        v[5] = o->oVelX; v[6] = o->oVelY; v[7] = o->oVelZ;
    }
    return n;
}
/* One walked back through the window: into the level at (x, y, z), going the way it was (game coordinates) */
EXPORT int sm64unity_room_object_return(int slot, float x, float y, float z, float vx, float vy, float vz) {
    if (slot < 0 || slot >= UNITY_ROOM_OBJECTS || unity_room_depth) return 0;
    struct UnityRoomObject *r = &unity_room_objects[slot];
    struct Object *o = r->obj;
    if (!o || o == unity_held_obj || !isfinite(x) || !isfinite(y) || !isfinite(z)) return 0;
    float p[3] = { x, y, z };
    unity_room_object_put_back(r, p);
    if (isfinite(vx) && isfinite(vy) && isfinite(vz)) {
        float along = sqrtf(vx * vx + vz * vz);
        o->oVelY = vy > 60.f ? 60.f : vy;
        o->oForwardVel = along > 60.f ? 60.f : along;
        if (along > 0.1f) { o->oMoveAngleYaw = atan2s(vz, vx); o->oFaceAngleYaw = o->oMoveAngleYaw; }
    }
    return 1;
}
/* Everything out in the room back where it was picked up in the level (leaving the room, Bring Mario back) */
EXPORT void sm64unity_room_objects_return(void) {
    if (unity_room_depth) return;
    if (unity_held_obj && unity_room_slot(unity_held_obj)) unity_held_obj = NULL;
    for (int i = 0; i < UNITY_ROOM_OBJECTS; i++)
        if (unity_room_objects[i].obj) unity_room_object_put_back(&unity_room_objects[i], unity_room_objects[i].from);
}
