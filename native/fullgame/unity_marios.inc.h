/* More Marios, out of the treasure chest (unity_spawn.inc.h). Included after it (in surface_load.c).
 *
 * The game has one Mario: one MarioState (gMarioState), one object (gMarioObject), one body state the model reads
 * (gBodyStates[0]), one buffer his animations load into. Each extra one has its own of each, and an object of its own
 * (bhvUnityMario, in the player list, Mario's model) whose step runs the game's own Mario code with them swapped in:
 * - the same controller, so they all run and jump as you steer, each from where it is;
 * - it touches what it runs into as Mario does (coins, caps, boxes, enemies to stomp or be hurt by), not other Marios,
 *   and nothing that would take the game somewhere else (warps, doors, stars, pipes, cannons) or that the camera would
 *   follow (poles, things to pick up, Bubba): the camera is the first Mario's;
 * - what it collects counts for the first Mario (his coins and lives);
 * - it's gone in a puff of smoke where the first Mario would warp or die (a death floor, health run out, out of
 *   bounds), and with any warp of his;
 * - in the level only, for now: not carried out into the room.
 * Its model reads its body state: it's swapped into gBodyStates[0] while its object is drawn (geo_process_object). */

#include "game/mario.h"
#include "game/mario_misc.h"
#include "game/game_init.h"
#include "game/interaction.h"
#include "game/obj_behaviors.h"
#include "sm64.h"

#define UNITY_EXTRA_MARIOS 3
/* What an extra Mario touches (the rest it passes through) */
#define UNITY_EXTRA_INTERACTIONS (INTERACT_DAMAGE | INTERACT_COIN | INTERACT_CAP | INTERACT_BREAKABLE | INTERACT_BOUNCE_TOP \
    | INTERACT_BOUNCE_TOP2 | INTERACT_HIT_FROM_BELOW | INTERACT_KOOPA | INTERACT_BULLY | INTERACT_FLAME | INTERACT_SHOCK \
    | INTERACT_SNUFIT_BULLET | INTERACT_MR_BLIZZARD | INTERACT_WATER_RING | INTERACT_STRONG_WIND | INTERACT_UNKNOWN_08)

struct UnityMario {
    struct Object *obj;
    struct MarioState m;
    struct MarioBodyState body;
    struct PlayerCameraState camera; /* (its own: the camera follows the first Mario) */
    struct MarioAnimation animation;
    u8 animationBuffer[0x4000] __attribute__((aligned(16))); /* (as the first Mario's, setup_game_memory) */
    int lost;           /* where the first Mario would warp or die: gone */
};
static struct UnityMario unity_marios[UNITY_EXTRA_MARIOS];
extern const BehaviorScript bhvUnityMario[];

static struct UnityMario *unity_mario_slot(struct Object *o) {
    if (!o) return NULL;
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++)
        if (unity_marios[i].obj == o) return &unity_marios[i];
    return NULL;
}
int unity_marios_extra(struct Object *o) { return unity_mario_slot(o) != NULL; }

static int unity_marios_count(void) {
    int n = 0;
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
        struct UnityMario *u = &unity_marios[i];
        if (!u->obj) continue;
        if (!(u->obj->activeFlags & ACTIVE_FLAG_ACTIVE) || u->obj->behavior != segmented_to_virtual(bhvUnityMario)) {
            u->obj = NULL; /* (unloaded with the level) */
            continue;
        }
        n++;
    }
    return n;
}
int unity_marios_can_spawn(void) {
    return gMarioObject && gMarioState && gMarioState->action && unity_marios_count() < UNITY_EXTRA_MARIOS;
}

/* Another Mario at (x, y, z) in the level, facing yaw: standing on the floor there, or falling to it. 1 if made */
int unity_marios_spawn(float x, float y, float z, s16 yaw) {
    if (!unity_marios_can_spawn() || unity_room_depth) return 0;
    struct Surface *floor;
    float floorHeight = find_floor(x, y + 100.f, z, &floor);
    if (!floor) return 0;
    struct UnityMario *u = NULL;
    for (int i = 0; i < UNITY_EXTRA_MARIOS && !u; i++) if (!unity_marios[i].obj) u = &unity_marios[i];
    if (!u) return 0;
    struct Object *o = spawn_object_abs_with_rot(gMarioObject, 0, MODEL_MARIO, bhvUnityMario, (s16) x, (s16) y, (s16) z,
                                                 0, yaw, 0);
    if (!o) return 0;
    o->parentObj = o;
    struct MarioState *m = &u->m;
    memset(m, 0, sizeof(*m));
    memset(&u->body, 0, sizeof(u->body));
    memset(&u->camera, 0, sizeof(u->camera));
    u->animation.animDmaTable = D_80339D10.animDmaTable;
    u->animation.currentAnimAddr = NULL;
    u->animation.targetAnim = (struct Animation *) u->animationBuffer;
    u->lost = 0;
    m->spawnInfo = gMarioState->spawnInfo;
    m->statusForCamera = &u->camera;
    m->marioBodyState = &u->body;
    m->controller = gMarioState->controller;
    m->animation = &u->animation;
    m->area = gCurrentArea;
    m->marioObj = o;
    m->flags = MARIO_CAP_ON_HEAD | MARIO_NORMAL_CAP;
    m->health = 0x880;
    m->unkB0 = gMarioState->unkB0; /* (how high his animations stand him: init_mario's 0xBD, or he's drawn sunk) */
    m->framesSinceA = m->framesSinceB = 0xFF;
    m->faceAngle[1] = yaw;
    m->pos[0] = x; m->pos[1] = y < floorHeight ? floorHeight : y; m->pos[2] = z;
    m->floor = floor; m->floorHeight = floorHeight;
    m->waterLevel = find_water_level(x, z);
    m->action = m->pos[1] > floorHeight + 10.f ? ACT_FREEFALL : ACT_IDLE;
    o->header.gfx.unk38.animID = -1;
    o->oPosX = m->pos[0]; o->oPosY = m->pos[1]; o->oPosZ = m->pos[2];
    vec3f_copy(o->header.gfx.pos, m->pos);
    vec3s_set(o->header.gfx.angle, 0, yaw, 0);
    o->activeFlags &= ~(ACTIVE_FLAG_FAR_AWAY | ACTIVE_FLAG_IN_DIFFERENT_ROOM);
    unity_skip_object_interpolation(o);
    u->obj = o;
    return 1;
}

/* level_trigger_warp for an extra Mario: no warp, it's gone instead. 1 if m was one */
int unity_marios_warp(struct MarioState *m) {
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++)
        if (unity_marios[i].obj && m == &unity_marios[i].m) { unity_marios[i].lost = 1; return 1; }
    return 0;
}
/* Is m an extra Mario (not the first)? */
int unity_marios_is_extra_state(struct MarioState *m) {
    return m != &gMarioStates[0];
}

/* All of them gone (a warp of the first Mario's) */
void unity_marios_warped(void) {
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
        struct UnityMario *u = &unity_marios[i];
        if (u->obj && (u->obj->activeFlags & ACTIVE_FLAG_ACTIVE)) obj_mark_for_deletion(u->obj);
        u->obj = NULL;
    }
}

/* Its step (bhvUnityMario's loop): the game's Mario code, as the first Mario's runs (bhv_mario_update), with this one's
 * state in place of his */
void unity_marios_update(void) {
    struct Object *o = gCurrentObject;
    struct UnityMario *u = unity_mario_slot(o);
    if (!u || !gMarioState || !gMarioObject) { obj_mark_for_deletion(o); return; }
    o->activeFlags &= ~(ACTIVE_FLAG_FAR_AWAY | ACTIVE_FLAG_IN_DIFFERENT_ROOM);
    struct MarioState *m = &u->m;
    /* (only what an extra one touches: update_mario_inputs reads them from its object) */
    o->collidedObjInteractTypes &= UNITY_EXTRA_INTERACTIONS;
    s16 coins = m->numCoins, lives = m->numLives;
    struct MarioState *first = gMarioState;
    struct Object *firstObj = gMarioObject;
    m->area = gCurrentArea;
    gMarioState = m; gMarioObject = o;
    execute_mario_action(o);
    gMarioState = first; gMarioObject = firstObj;
    /* (bhv_mario_update's copy_mario_state_to_object, from its own state) */
    o->oVelX = m->vel[0]; o->oVelY = m->vel[1]; o->oVelZ = m->vel[2];
    o->oPosX = m->pos[0]; o->oPosY = m->pos[1]; o->oPosZ = m->pos[2];
    o->oMoveAnglePitch = o->oFaceAnglePitch = o->header.gfx.angle[0];
    o->oMoveAngleYaw = o->oFaceAngleYaw = o->header.gfx.angle[1];
    o->oMoveAngleRoll = o->oFaceAngleRoll = o->header.gfx.angle[2];
    o->oAngleVelPitch = m->angleVel[0]; o->oAngleVelYaw = m->angleVel[1]; o->oAngleVelRoll = m->angleVel[2];
    /* What it collects counts for the first Mario */
    if (m->numCoins != coins) {
        first->numCoins += m->numCoins - coins;
        first->healCounter += 4 * (m->numCoins - coins);
    }
    if (m->numLives != lives) first->numLives += m->numLives - lives;
    m->numLives = 0;
    if (u->lost || !m->floor || m->health < 0x100) {
        spawn_mist_particles_variable(0, 0, 46.f);
        obj_mark_for_deletion(o);
        u->obj = NULL;
    }
}

/* Drawing it (geo_process_object): its body state where the model reads Mario's (begin 1), then the first Mario's back
 * (begin 0) */
static struct MarioBodyState unity_marios_first_body;
static struct UnityMario *unity_marios_drawing;
void unity_marios_body(struct Object *o, int begin) {
    if (begin) {
        struct UnityMario *u = unity_mario_slot(o);
        if (!u || unity_marios_drawing) return;
        unity_marios_first_body = gBodyStates[0];
        gBodyStates[0] = u->body;
        unity_marios_drawing = u;
    } else if (unity_marios_drawing && unity_marios_drawing->obj == o) {
        gBodyStates[0] = unity_marios_first_body;
        unity_marios_drawing = NULL;
    }
}

/* Where they are (for the host): 4 floats each, x y z and yaw (the level's coordinates). How many */
EXPORT int sm64unity_marios(float *out, int max) {
    if (!out || max <= 0) return 0;
    int n = 0;
    for (int i = 0; i < UNITY_EXTRA_MARIOS && n < max; i++) {
        struct UnityMario *u = &unity_marios[i];
        if (!u->obj || !(u->obj->activeFlags & ACTIVE_FLAG_ACTIVE)) continue;
        float *v = out + n++ * 4;
        v[0] = u->m.pos[0]; v[1] = u->m.pos[1]; v[2] = u->m.pos[2]; v[3] = u->m.faceAngle[1];
    }
    return n;
}
