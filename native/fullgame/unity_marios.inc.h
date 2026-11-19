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
 * Or it's a Mario of its own (an NPC: the disc stage's, unity_stage.inc.h), steered by a controller of its own that
 * stage_npc_think works: it goes where it means to whichever way the camera faces (unity_marios_steer).
 * Rolled along by another Mario, or tumbling on after (the stage's too), it runs none of the game's Mario code:
 * stage_tumble_step moves and turns it.
 * Its model reads its body state: it's swapped into gBodyStates[0] while its object is drawn (geo_process_object);
 * and what it holds is its own (unity_marios_drawn: the model's held object node).
 * Tilted to the floor (crawling, sliding: align_with_floor), it's drawn by a matrix of its own: the game keeps one a
 * player (sFloorAlignMatrix[m->unk00]), so each extra one's step uses player 2's, then copies it out. */

#include "game/mario.h"
#include "game/mario_misc.h"
#include "game/game_init.h"
#include "game/interaction.h"
#include "game/obj_behaviors.h"
#include "sm64.h"
#include "engine/math_util.h"

/* Holding what another Mario has taken? (Two grabbed it in one step: it's the last one's, its parentObj.) Then empty
 * handed, as he was (m, with gMarioState and gMarioObject his) */
static void unity_marios_let_go_taken(struct MarioState *m) {
    struct Object *held = m->heldObj;
    if (!held || (held->oHeldState == HELD_HELD && held->parentObj == m->marioObj)) return;
    m->heldObj = NULL;
    if (m->action & ACT_FLAG_AIR) set_mario_action(m, ACT_FREEFALL, 0);
    else set_mario_action(m, ACT_IDLE, 0);
}

/* Out of the treasure chest at once, and of their own (NPCs) */
#define UNITY_CHEST_MARIOS 3
#define UNITY_NPC_MARIOS 128
#define UNITY_EXTRA_MARIOS (UNITY_CHEST_MARIOS + UNITY_NPC_MARIOS)
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
    Mat4 floorAlign;    /* tilted to the floor: how it's drawn (its object's throwMatrix) */
    int npc;            /* steered by its own controller, not yours */
    struct Controller pad;
    struct { int mode, timer, hold; float x, z; s16 yaw; u32 seed; struct UnityMario *target; struct Object *box; } brain; /* (stage_npc_think's) */
    int tumbling;       /* rolled along, or tumbling on (stage_tumble_step's) */
    struct { struct MarioState *by; float speed; s16 dir, spin; } tumble;
};
extern Mat4 sFloorAlignMatrix[2]; /* (mario_actions_moving.c: a player each, by MarioState's unk00) */
static struct UnityMario unity_marios[UNITY_EXTRA_MARIOS];
extern const BehaviorScript bhvUnityMario[];
static void stage_npc_think(struct UnityMario *u); /* (unity_stage.inc.h) */
static void stage_tumble_step(struct UnityMario *u);

/* (its object's oBehParams is its slot's, from 1) */
static struct UnityMario *unity_mario_slot(struct Object *o) {
    if (!o || o->behavior != segmented_to_virtual(bhvUnityMario)) return NULL;
    u32 i = (u32) o->oBehParams - 1;
    return i < UNITY_EXTRA_MARIOS && unity_marios[i].obj == o ? &unity_marios[i] : NULL;
}
int unity_marios_extra(struct Object *o) { return unity_mario_slot(o) != NULL; }

static int unity_marios_count(int npc) {
    int n = 0;
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
        struct UnityMario *u = &unity_marios[i];
        if (!u->obj) continue;
        if (!(u->obj->activeFlags & ACTIVE_FLAG_ACTIVE) || u->obj->behavior != segmented_to_virtual(bhvUnityMario)) {
            u->obj = NULL; /* (unloaded with the level) */
            continue;
        }
        if (u->npc == npc) n++;
    }
    return n;
}
static int unity_marios_ready(void) { return gMarioObject && gMarioState && gMarioState->action && !unity_room_depth; }
int unity_marios_can_spawn(void) { return unity_marios_ready() && unity_marios_count(0) < UNITY_CHEST_MARIOS; }
int unity_marios_npcs(void) { return unity_marios_count(1); }

/* Another Mario at (x, y, z) in the level, facing yaw: standing on the floor there, or falling to it. NULL if none */
static struct UnityMario *unity_marios_make(float x, float y, float z, s16 yaw, int npc) {
    if (unity_marios_count(npc) >= (npc ? UNITY_NPC_MARIOS : UNITY_CHEST_MARIOS)) return NULL;
    struct Surface *floor;
    float floorHeight = find_floor(x, y + 100.f, z, &floor);
    if (!floor) return NULL;
    struct UnityMario *u = NULL;
    int slot = 0;
    for (; slot < UNITY_EXTRA_MARIOS && !u; slot++) if (!unity_marios[slot].obj) u = &unity_marios[slot];
    if (!u) return NULL;
    struct Object *o = spawn_object_abs_with_rot(gMarioObject, 0, MODEL_MARIO, bhvUnityMario, (s16) x, (s16) y, (s16) z,
                                                 0, yaw, 0);
    if (!o) return NULL;
    o->parentObj = o;
    o->oBehParams = slot; /* (from 1: unity_mario_slot) */
    struct MarioState *m = &u->m;
    memset(m, 0, sizeof(*m));
    memset(&u->body, 0, sizeof(u->body));
    memset(&u->camera, 0, sizeof(u->camera));
    u->animation.animDmaTable = D_80339D10.animDmaTable;
    u->animation.currentAnimAddr = NULL;
    u->animation.targetAnim = (struct Animation *) u->animationBuffer;
    u->lost = 0;
    u->npc = npc;
    memset(&u->pad, 0, sizeof(u->pad));
    memset(&u->brain, 0, sizeof(u->brain));
    u->tumbling = 0;
    memset(&u->tumble, 0, sizeof(u->tumble));
    u->brain.seed = 0x9E3779B9u * (u32) slot;
    m->spawnInfo = gMarioState->spawnInfo;
    m->statusForCamera = &u->camera;
    m->marioBodyState = &u->body;
    m->controller = npc ? &u->pad : gMarioState->controller;
    m->animation = &u->animation;
    m->area = gCurrentArea;
    m->marioObj = o;
    m->flags = MARIO_CAP_ON_HEAD | MARIO_NORMAL_CAP;
    m->health = 0x880;
    m->unk00 = 1; /* (player 2's floor tilt, not the first Mario's: copied out after each step) */
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
    return u;
}
int unity_marios_spawn(float x, float y, float z, s16 yaw) {
    return unity_marios_can_spawn() && unity_marios_make(x, y, z, yaw, 0);
}

/* Its own controller's direction is the world's, not the camera's (update_mario_joystick_inputs, after it has read
 * the stick's) */
void unity_marios_steer(struct MarioState *m) {
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
        struct UnityMario *u = &unity_marios[i];
        if (m != &u->m) continue;
        if (u->npc && m->intendedMag > 0.f) m->intendedYaw = u->brain.yaw;
        return;
    }
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
    /* (only what an extra one touches: update_mario_inputs reads them from its object; an NPC picks boxes up too) */
    o->collidedObjInteractTypes &= UNITY_EXTRA_INTERACTIONS | (u->npc ? INTERACT_GRABBABLE : 0);
    s16 coins = m->numCoins, lives = m->numLives;
    struct MarioState *first = gMarioState;
    struct Object *firstObj = gMarioObject;
    m->area = gCurrentArea;
    if (u->npc && !u->tumbling) stage_npc_think(u); /* (gMarioState still the first Mario) */
    gMarioState = m; gMarioObject = o;
    unity_marios_let_go_taken(m);
    if (u->tumbling) stage_tumble_step(u);
    else execute_mario_action(o);
    gMarioState = first; gMarioObject = firstObj;
    /* Tilted to the floor: its own copy of the tilt, or the next one's step would move it there */
    if (o->header.gfx.throwMatrix == &sFloorAlignMatrix[m->unk00]) {
        mtxf_copy(u->floorAlign, sFloorAlignMatrix[m->unk00]);
        o->header.gfx.throwMatrix = &u->floorAlign;
    }
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
        if (m->heldObj) { m->heldObj->oHeldState = HELD_DROPPED; m->heldObj = NULL; } /* (what it held, let fall) */
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

/* The extra Mario being drawn, if one is (its model's held object node draws what it holds, not the first Mario's) */
struct MarioState *unity_marios_drawn(void) { return unity_marios_drawing ? &unity_marios_drawing->m : NULL; }

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
