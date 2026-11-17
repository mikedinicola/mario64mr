/* The treasure chest by the window (the host's TreasureChest): enemies, power-up boxes and more Marios taken out of
 * it. Included after unity_room_objects.inc.h (in surface_load.c).
 *
 * - A cheat (the Cheats menu's Treasure chest, on by default): off, nothing comes out of it, and with nothing to offer
 *   the host doesn't show it.
 * - Taken out with a pinch, one is made where the pinch is and held by it at once (unity_hold): out in the room (a room
 *   slot of its own) or in the level, from then on carried, put down and gone back in like anything a pinch picked up
 *   (unity_hands.inc.h, unity_room_objects.inc.h). Taken out with a look, it's put in the level in front of Mario
 *   (out in the room, if he's out there).
 * - It has no place in the level to go back to: where something carried out would go back where it was picked up
 *   (no floor under it in the room, the room left, a warp), what came out of the chest is gone instead.
 * - A power-up box is always solid (its parameters' top byte: as after its cap switch), and floats rather than falls:
 *   let go of, it rises or sinks to BOX_REACH over the floor under it, where Mario's head reaches it with a jump. Once
 *   broken it's gone (not back after a while, as the level's own cap boxes are).
 * - A Koopa shell is the one a box lets out: Mario rides it by walking into it or landing on it, and it's gone in a
 *   puff once he's off it (bhv_koopa_shell_loop). Ridden, it isn't the hands' to take.
 * - At most UNITY_SPAWN_EACH of a kind at once. */

#include "behavior_data.h"
#include "model_ids.h"
#include "object_constants.h"
#include "game/object_helpers.h"
#include "game/object_list_processor.h"
#include "game/camera.h"
#include "game/area.h"
#include "game/level_update.h"
#include "engine/math_util.h"
#include "engine/surface_collision.h"
#include "pc/unity_options.h"

/* The kinds, in the host's order (SpawnKind) */
enum {
    UNITY_SPAWN_GOOMBA, UNITY_SPAWN_BOBOMB, UNITY_SPAWN_KOOPA, UNITY_SPAWN_CHUCKYA, UNITY_SPAWN_BULLY,
    UNITY_SPAWN_WING_BOX, UNITY_SPAWN_METAL_BOX, UNITY_SPAWN_VANISH_BOX, UNITY_SPAWN_COIN_BOX, UNITY_SPAWN_1UP_BOX,
    UNITY_SPAWN_MARIO, UNITY_SPAWN_SHELL, UNITY_SPAWN_KINDS
};
struct UnitySpawnKind {
    int model;
    const BehaviorScript *behavior;
    u32 params;         /* oBehParams (its 2nd byte too) */
    int contents;       /* a box's contents' model, which has to be loaded too (0 none) */
};
#define UNITY_BOX(contents) ((1u << 24) | ((u32) (contents) << 16)) /* (top byte: solid whatever the save says) */
static const struct UnitySpawnKind unity_spawn_kinds[UNITY_SPAWN_KINDS] = {
    { MODEL_GOOMBA, bhvGoomba, 0, 0 },
    { MODEL_BLACK_BOBOMB, bhvBobomb, 0, 0 },
    { MODEL_KOOPA_WITH_SHELL, bhvKoopa, KOOPA_BP_NORMAL << 16, 0 },
    { MODEL_CHUCKYA, bhvChuckya, 0, 0 },
    { MODEL_BULLY, bhvSmallBully, 0, 0 },
    { MODEL_EXCLAMATION_BOX, bhvExclamationBox, UNITY_BOX(0), MODEL_MARIOS_WING_CAP },
    { MODEL_EXCLAMATION_BOX, bhvExclamationBox, UNITY_BOX(1), MODEL_MARIOS_METAL_CAP },
    { MODEL_EXCLAMATION_BOX, bhvExclamationBox, UNITY_BOX(2), MODEL_MARIOS_CAP },
    { MODEL_EXCLAMATION_BOX, bhvExclamationBox, UNITY_BOX(5), MODEL_YELLOW_COIN }, /* (three: room for them out there) */
    { MODEL_EXCLAMATION_BOX, bhvExclamationBox, UNITY_BOX(7), MODEL_1UP },
    { MODEL_MARIO, NULL, 0, 0 }, /* (unity_marios.inc.h) */
    { MODEL_KOOPA_SHELL, bhvKoopaShell, 0, 0 }, /* (to ride: in every course, as a box's shell is) */
};
#define UNITY_SPAWN_EACH 6
/* A box's origin over the floor, game units: its underside (60 over its origin, at its scale of 2) at 320, where
 * Mario (160 tall) walks under it, and a single jump from standing (his feet 240 up) puts his head into it */
#define BOX_REACH 260.f

#define UNITY_SPAWNED 32
struct UnitySpawned {
    struct Object *obj;
    const BehaviorScript *behavior;
    int kind;
    int settled;        /* a box: at its height over the floor under where it was let go of */
    float target;       /* ...that height */
};
static struct UnitySpawned unity_spawned_objects[UNITY_SPAWNED];

static struct UnitySpawned *unity_spawned_slot(struct Object *o) {
    if (!o) return NULL;
    for (int i = 0; i < UNITY_SPAWNED; i++)
        if (unity_spawned_objects[i].obj == o) return &unity_spawned_objects[i];
    return NULL;
}
int unity_spawned(struct Object *o) { return unity_spawned_slot(o) != NULL; }
/* (what a box out in the room let out, taken into the room too: no kind of its own) */
#define UNITY_SPAWN_CONTENTS UNITY_SPAWN_KINDS
static int unity_spawned_box(struct Object *o) {
    struct UnitySpawned *s = unity_spawned_slot(o);
    return s && s->kind < UNITY_SPAWN_KINDS && unity_spawn_kinds[s->kind].behavior == bhvExclamationBox;
}

static int unity_spawn_count(int kind) {
    int n = 0;
    for (int i = 0; i < UNITY_SPAWNED; i++) {
        struct UnitySpawned *s = &unity_spawned_objects[i];
        if (s->obj && s->kind == kind) n++;
    }
    return n;
}

extern int unity_mario_held(void);
extern int unity_marios_can_spawn(void);
extern int unity_marios_spawn(float x, float y, float z, s16 yaw);

/* Can the level make one now? Its model (and a box's contents') loaded, Mario in the level, nothing holding it still */
static int unity_spawn_kind_available(int kind) {
    if (kind < 0 || kind >= UNITY_SPAWN_KINDS || !gMarioObject || !gMarioState || !gCurrentArea) return 0;
    if (!unity_hand_cheat(UNITY_HAND_CHEST)) return 0;  /* (the Cheats menu's Treasure chest: off, nothing to spawn) */
    if ((gTimeStopState & TIME_STOP_ACTIVE) || (gCamera && gCamera->cutscene)) return 0;
    const struct UnitySpawnKind *k = &unity_spawn_kinds[kind];
    if (kind == UNITY_SPAWN_MARIO) return unity_marios_can_spawn();
    if (!gLoadedGraphNodes[k->model] || (k->contents && !gLoadedGraphNodes[k->contents])) return 0;
    return unity_spawn_count(kind) < UNITY_SPAWN_EACH;
}
/* Which kinds the level can make now, bit by kind */
EXPORT unsigned int sm64unity_spawn_available(void) {
    unsigned int mask = 0;
    for (int k = 0; k < UNITY_SPAWN_KINDS; k++) if (unity_spawn_kind_available(k)) mask |= 1u << k;
    return mask;
}

/* Gone: what came out of the chest has nowhere in the level to go back to */
static void unity_spawned_remove(struct Object *o) {
    struct UnitySpawned *s = unity_spawned_slot(o);
    if (s) s->obj = NULL;
    if (unity_held_obj == o) unity_held_obj = NULL;
    obj_mark_for_deletion(o); /* (unloaded with the others at the end of the objects' frame) */
}

/* Made at p (the level's coordinates, or the room's), facing yaw: nobody's child, not far away */
static struct Object *unity_spawn_make(int kind, const float p[3], s16 yaw) {
    const struct UnitySpawnKind *k = &unity_spawn_kinds[kind];
    struct UnitySpawned *s = NULL;
    for (int i = 0; i < UNITY_SPAWNED && !s; i++) if (!unity_spawned_objects[i].obj) s = &unity_spawned_objects[i];
    if (!s) return NULL;
    struct Object *o = spawn_object_abs_with_rot(gMarioObject, 0, k->model, k->behavior, (s16) p[0], (s16) p[1],
                                                 (s16) p[2], 0, yaw, 0);
    if (!o) return NULL;
    o->oPosX = p[0]; o->oPosY = p[1]; o->oPosZ = p[2];
    o->oHomeX = p[0]; o->oHomeY = p[1]; o->oHomeZ = p[2];
    o->oBehParams = k->params;
    o->oBehParams2ndByte = (k->params >> 16) & 0xFF;
    o->parentObj = o;
    o->activeFlags &= ~(ACTIVE_FLAG_FAR_AWAY | ACTIVE_FLAG_IN_DIFFERENT_ROOM);
    s->obj = o; s->behavior = o->behavior; s->kind = kind; s->settled = 0; s->target = p[1];
    unity_skip_object_interpolation(o);
    return o;
}

/* The way from p to Mario, level (to face him) */
static s16 unity_spawn_facing(const float p[3]) {
    if (!gMarioState) return 0;
    return atan2s(gMarioState->pos[2] - p[2], gMarioState->pos[0] - p[0]);
}

/* Taken out with a pinch at (x, y, z): in the room's coordinates (in_room) or the level's. Held by the pinch at once,
 * as sm64unity_object_grab would hold it (and out in the room, as sm64unity_object_hold_room). 1 if one was made and
 * is held; 2 for another Mario (not held: put down there, unity_marios.inc.h) */
EXPORT int sm64unity_spawn_held(int kind, int in_room, float x, float y, float z) {
    if (!isfinite(x) || !isfinite(y) || !isfinite(z) || unity_room_depth) return 0;
    if (!unity_spawn_kind_available(kind) || unity_still_held() || unity_mario_held()) return 0;
    if (in_room && unity_room_surface_count() == 0) return 0;
    float p[3] = { x, y, z };
    if (kind == UNITY_SPAWN_MARIO) {
        if (in_room) return 0; /* (the host puts him beside Mario instead) */
        return unity_marios_spawn(x, y, z, unity_spawn_facing(p)) ? 2 : 0;
    }
    struct Object *o = unity_spawn_make(kind, p, unity_spawn_facing(p));
    if (!o) return 0;
    if (in_room) {
        /* (its "from", for going back into the level, is never used: it's gone instead, unity_spawned_remove) */
        if (!unity_room_object_take(o, p)) { unity_spawned_remove(o); return 0; }
        o->header.gfx.node.flags |= GRAPH_RENDER_ACTIVE;
    }
    unity_hold(o, x, y, z);
    unity_held_from[0] = x; unity_held_from[1] = y; unity_held_from[2] = z;
    /* (held by its top, as it hangs from the pinch) */
    unity_held_offset[1] = unity_spawned_box(o) ? -80.f : -40.f;
    unity_hands_place_held();
    return 1;
}

/* Taken out with a look: put down in front of Mario, a step away (out in the room if he's out there). 1 if made */
EXPORT int sm64unity_spawn_near_mario(int kind) {
    if (!unity_spawn_kind_available(kind) || unity_room_depth) return 0;
    s16 yaw = gMarioState->faceAngle[1];
    float p[3] = { gMarioState->pos[0] + sins(yaw) * 220.f, gMarioState->pos[1] + 60.f,
                   gMarioState->pos[2] + coss(yaw) * 220.f };
    int outside = unity_mario_outside();
    float floor;
    if (outside ? !unity_room_floor(p[0], p[1] + 200.f, p[2], &floor) : 0) return 0;
    if (!outside) {
        struct Surface *surface;
        floor = find_floor(p[0], p[1] + 200.f, p[2], &surface);
        if (!surface) return 0;
    }
    p[1] = floor + 20.f;
    s16 facing = (s16) (yaw + 0x8000);
    if (kind == UNITY_SPAWN_MARIO) {
        if (outside) return 0;
        /* (beside him rather than in front: they run side by side) */
        p[0] = gMarioState->pos[0] + coss(yaw) * 160.f; p[2] = gMarioState->pos[2] - sins(yaw) * 160.f;
        p[1] = gMarioState->pos[1];
        return unity_marios_spawn(p[0], p[1], p[2], yaw);
    }
    struct Object *o = unity_spawn_make(kind, p, facing);
    if (!o) return 0;
    if (outside) {
        if (!unity_room_object_take(o, p)) { unity_spawned_remove(o); return 0; }
        o->header.gfx.node.flags |= GRAPH_RENDER_ACTIVE;
        o->oHomeY = floor;
    }
    return 1;
}

/* What a box lets out (sExclamationBoxContents, and the coins a coin spawner makes) */
static int unity_box_contents(const BehaviorScript *b) {
#define UNITY_IS(bhv) (b == segmented_to_virtual(bhv))
    return UNITY_IS(bhvWingCap) || UNITY_IS(bhvMetalCap) || UNITY_IS(bhvVanishCap) || UNITY_IS(bhvSingleCoinGetsSpawned)
        || UNITY_IS(bhvYellowCoin) || UNITY_IS(bhvThreeCoinsSpawn) || UNITY_IS(bhvTenCoinsSpawn) || UNITY_IS(bhv1upWalking)
        || UNITY_IS(bhvKoopaShell);
#undef UNITY_IS
}
/* Something a box let out that changed its behaviour as it began (a spawned coin becomes a yellow coin, bhv_coin_init):
 * still the same thing, not another object made in its place. 1 if so (its new behaviour kept) */
static int unity_spawned_rebehaved(struct Object *o) {
    struct UnitySpawned *s = unity_spawned_slot(o);
    if (!s || s->kind != UNITY_SPAWN_CONTENTS || !(o->activeFlags & ACTIVE_FLAG_ACTIVE)) return 0;
    if (!unity_box_contents(o->behavior)) return 0;
    s->behavior = o->behavior;
    return 1;
}
/* What a box out in the room let out (made in the level's lists, at the box's place in the room) goes out there with
 * it, there to be collected by Mario out there; gone when it would go back into the level */
static void unity_spawned_adopt(void) {
    if (unity_room_object_count == 0) return;
    for (int l = 0; l < NUM_OBJ_LISTS; l++) {
        struct ObjectNode *head = &gObjectLists[l];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node, *p = o->parentObj;
            if (!(o->activeFlags & ACTIVE_FLAG_ACTIVE) || !p || p == o || unity_room_slot(o)) continue;
            if (!unity_room_slot(p) || !unity_spawned(p) || !unity_box_contents(o->behavior)) continue;
            struct UnitySpawned *s = NULL;
            for (int i = 0; i < UNITY_SPAWNED && !s; i++) if (!unity_spawned_objects[i].obj) s = &unity_spawned_objects[i];
            float at[3] = { o->oPosX, o->oPosY, o->oPosZ };
            if (!s || !unity_room_object_take(o, at)) { obj_mark_for_deletion(o); continue; }
            s->obj = o; s->behavior = o->behavior; s->kind = UNITY_SPAWN_CONTENTS; s->settled = 1;
            o->header.gfx.node.flags |= GRAPH_RENDER_ACTIVE;
        }
    }
}

/* At the start of the objects' frame: forget what's gone; boxes not held float to their height over the floor */
static void unity_spawned_frame(void) {
    unity_spawned_adopt();
    for (int i = 0; i < UNITY_SPAWNED; i++) {
        struct UnitySpawned *s = &unity_spawned_objects[i];
        struct Object *o = s->obj;
        if (!o) continue;
        if (o->behavior != s->behavior) unity_spawned_rebehaved(o);
        if (!(o->activeFlags & ACTIVE_FLAG_ACTIVE) || o->behavior != s->behavior) { s->obj = NULL; continue; }
        if (s->kind >= UNITY_SPAWN_KINDS || unity_spawn_kinds[s->kind].behavior != bhvExclamationBox) continue;
        /* (broken: gone, not back after a while) */
        if (o->oAction >= 5) { unity_spawned_remove(o); continue; }
        if (o == unity_held_obj) { s->settled = 0; continue; }
        if (o->oAction >= 3) continue; /* (breaking) */
        if (!s->settled) {
            float floor;
            int found;
            if (unity_object_in_room(o)) found = unity_room_floor(o->oPosX, o->oPosY, o->oPosZ, &floor);
            else {
                struct Surface *surface;
                floor = find_floor(o->oPosX, o->oPosY, o->oPosZ, &surface);
                found = surface != NULL;
            }
            if (!found) { unity_spawned_remove(o); continue; }
            s->target = floor + BOX_REACH;
            s->settled = 1;
        }
        o->oVelX = o->oVelY = o->oVelZ = 0;
        o->oForwardVel = 0;
        float dy = s->target - o->oPosY;
        o->oPosY = fabsf(dy) < 1.f ? s->target : o->oPosY + dy * 0.25f;
        o->oHomeY = s->target;
        o->header.gfx.pos[1] = o->oPosY;
    }
}
