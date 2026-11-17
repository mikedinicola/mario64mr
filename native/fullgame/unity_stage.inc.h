/* The disc stage (Castle Grounds' area 2: stage_disc.inc.c): its boxes. Included after unity_marios.inc.h (in
 * surface_load.c).
 *
 * - A box (bhvStageBox) is picked up, carried and thrown as the game's small cork box is (Mario's own grab and throw),
 *   but never breaks nor goes away: thrown off the disc's edge it bounces back onto it, and it slides to a stop.
 * - It's drawn in a colour of its own (its oBehParams, 0xRRGGBB: geo_stage_box).
 * - Arriving on the stage, the boxes lie on the disc as a picture, one a pixel (bhvStageMosaic, stage_mosaic.inc.h from
 *   mosaic.png, yours in stage/local/ else stage/'s placeholder, made by stage_gen.py), the picture's top furthest
 *   from the stage's pipe.
 * - The first time Mario picks one up, another Mario hops out of where it lay (stage_box_mario): an NPC, a Mario of
 *   its own (unity_marios.inc.h) with a mind of its own (stage_npc_think): it stands about, wanders the disc, runs
 *   over to Mario, now and then jumps, and keeps away from the edge. Up to UNITY_NPC_MARIOS of them; they're gone as
 *   the extra Marios are, when Mario leaves the stage.
 * - How many Marios there are (Mario too) is counted at the bottom of the screen, in the HUD's own letters
 *   (stage_hud, after the rest of the HUD). */

#include "levels/castle_grounds/header.h"
#include "game/memory.h"
#include "game/rendering_graph_node.h"
#include "audio/external.h"
#include "game/spawn_sound.h"
#include "game/print.h"
#include "game/level_update.h"
#include "pc/stage_mosaic.inc.h"

/* (obj_behaviors.c's own, as its objects step: on the floor, into a wall) */
extern s16 object_step(void);
#define STAGE_COL_GROUNDED (1 << 0)
#define STAGE_COL_HIT_WALL (1 << 1)

/* The pixels' spacing on the disc, game units (a box is 100 across), and where the picture's middle is */
#define STAGE_MOSAIC_SPACING 130.f
#define STAGE_MOSAIC_Z -300.f
/* Thrown: how fast it flies off, and how quickly it stops sliding on the disc */
#define STAGE_BOX_THROW_SPEED 40.f
#define STAGE_BOX_THROW_RISE 20.f
#define STAGE_BOX_GROUND_FRICTION 0.85f
/* An NPC Mario: where on the disc it wanders to (within this of its middle), past where it turns back to the
 * middle, how near it runs up to Mario, how fast it walks (the stick's tilt, of 64), how often it jumps */
#define STAGE_NPC_ROAM 2300.f
#define STAGE_NPC_SAFE 2600.f
#define STAGE_NPC_NEAR_MARIO 350.f
#define STAGE_NPC_WALK 48.f
#define STAGE_NPC_JUMP_ONE_IN 200

static struct ObjectHitbox stage_box_hitbox = {
    /* interactType:      */ INTERACT_GRABBABLE,
    /* downOffset:        */ 0,
    /* damageOrCoinValue: */ 0,
    /* health:            */ 1,
    /* numLootCoins:      */ 0,
    /* radius:            */ 80,
    /* height:            */ 100,
    /* hurtboxRadius:     */ 80,
    /* hurtboxHeight:     */ 100,
};

void stage_box_init(void) {
    struct Object *o = gCurrentObject;
    o->oGravity = 2.5f;
    o->oFriction = 0.99f;
    o->oBuoyancy = 1.4f;
    obj_set_hitbox(o, &stage_box_hitbox);
}

/* Flying (thrown), it knocks what it hits as the cork box does (obj_attack_collided_from_other_object), but not Marios
 * nor the other boxes: they lie touching each other, and an attack marks a box as interacted with, so Mario couldn't
 * pick it up */
static void stage_box_attack(struct Object *o) {
    if (o->oForwardVel < 10.f) return;
    const BehaviorScript *box = segmented_to_virtual(bhvStageBox);
    for (int i = 0; i < o->numCollidedObjs; i++) {
        struct Object *other = o->collidedObjs[i];
        if (other == gMarioObject || unity_marios_extra(other) || other->behavior == box) continue;
        other->oInteractStatus |= ATTACK_PUNCH | INT_STATUS_WAS_ATTACKED | INT_STATUS_INTERACTED | INT_STATUS_TOUCHED_BOB_OMB;
    }
}

/* Another Mario, out of where the box lay (its first time picked up). 1 if one came */
int stage_box_mario(struct Object *o) {
    if (!unity_marios_ready()) return 0;
    float x = o->oHomeX, z = o->oHomeZ;
    s16 yaw = atan2s(gMarioState->pos[2] - z, gMarioState->pos[0] - x); /* (facing Mario) */
    struct UnityMario *u = unity_marios_make(x, 0.f, z, yaw, 1);
    if (!u) return 0;
    u->m.action = ACT_JUMP; /* (it hops out) */
    u->m.vel[1] = 42.f;
    u->brain.mode = 0;
    u->brain.timer = 30;
    play_sound(SOUND_GENERAL_COLLECT_1UP, gDefaultSoundArgs);
    return 1;
}

/* An NPC Mario's mind: what its controller does this step */
enum { STAGE_NPC_IDLE, STAGE_NPC_WANDER, STAGE_NPC_FOLLOW };
static u32 stage_npc_random(struct UnityMario *u) {
    u32 x = u->brain.seed ? u->brain.seed : 1;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return u->brain.seed = x;
}
static int stage_npc_between(struct UnityMario *u, int lo, int hi) { return lo + (int) (stage_npc_random(u) % (u32) (hi - lo + 1)); }

static void stage_npc_think(struct UnityMario *u) {
    struct MarioState *m = &u->m;
    struct Controller *pad = &u->pad;
    /* What next, its time up for this */
    if (--u->brain.timer <= 0) {
        if (u->brain.mode == STAGE_NPC_IDLE) {
            if (stage_npc_between(u, 0, 9) < 7) {
                u->brain.mode = STAGE_NPC_WANDER;
                float a = stage_npc_between(u, 0, 0xFFFF), r = STAGE_NPC_ROAM * sqrtf(stage_npc_between(u, 0, 1000) / 1000.f);
                u->brain.x = r * sins((s16) a);
                u->brain.z = r * coss((s16) a);
                u->brain.timer = stage_npc_between(u, 90, 300);
            } else {
                u->brain.mode = STAGE_NPC_FOLLOW;
                u->brain.timer = stage_npc_between(u, 120, 240);
            }
        } else {
            u->brain.mode = STAGE_NPC_IDLE;
            u->brain.timer = stage_npc_between(u, 20, 90);
        }
    }
    if (u->brain.mode == STAGE_NPC_FOLLOW && gMarioState) {
        u->brain.x = gMarioState->pos[0];
        u->brain.z = gMarioState->pos[2];
    }
    float speed = 0.f;
    if (sqrtf(m->pos[0] * m->pos[0] + m->pos[2] * m->pos[2]) > STAGE_NPC_SAFE) { /* (near the edge: back to the middle) */
        u->brain.mode = STAGE_NPC_WANDER;
        u->brain.x = u->brain.z = 0.f;
        u->brain.timer = 60;
    }
    if (u->brain.mode != STAGE_NPC_IDLE) {
        float dx = u->brain.x - m->pos[0], dz = u->brain.z - m->pos[2];
        if (sqrtf(dx * dx + dz * dz) < (u->brain.mode == STAGE_NPC_FOLLOW ? STAGE_NPC_NEAR_MARIO : 120.f)) {
            u->brain.mode = STAGE_NPC_IDLE;
            u->brain.timer = stage_npc_between(u, 20, 90);
        } else {
            u->brain.yaw = atan2s(dz, dx);
            speed = u->brain.mode == STAGE_NPC_FOLLOW ? 64.f : STAGE_NPC_WALK;
        }
    }
    /* Now and then, on its way, a jump (A held a while, for its full height) */
    u16 down = 0;
    if (u->brain.hold > 0) { u->brain.hold--; down = A_BUTTON; }
    else if (speed > 0.f && stage_npc_between(u, 1, STAGE_NPC_JUMP_ONE_IN) == 1) { u->brain.hold = 10; down = A_BUTTON; }
    pad->buttonPressed = down & ~pad->buttonDown;
    pad->buttonDown = down;
    pad->stickX = 0.f; /* (straight ahead: unity_marios_steer turns it the way it means) */
    pad->stickY = pad->stickMag = speed;
    pad->rawStickX = 0; pad->rawStickY = (s16) speed;
}

static void stage_box_move(struct Object *o) {
    s16 collisions = object_step();
    stage_box_attack(o);
    if (collisions == STAGE_COL_GROUNDED) cur_obj_play_sound_2(SOUND_GENERAL_BOX_LANDING_2);
    if (collisions & STAGE_COL_HIT_WALL) /* (past the rim, nothing to land on: object_step turned it back) */
        o->oForwardVel *= 0.5f;
    if (collisions & STAGE_COL_GROUNDED) {
        o->oForwardVel *= STAGE_BOX_GROUND_FRICTION;
        if (o->oForwardVel < 1.f) o->oForwardVel = 0.f;
    }
}

void stage_box_loop(void) {
    struct Object *o = gCurrentObject;
    switch (o->oHeldState) {
        case HELD_FREE:
            stage_box_move(o);
            break;
        case HELD_HELD:
            if (!o->oAction && gMarioState && gMarioState->heldObj == o) { /* (its first time) */
                o->oAction = 1;
                stage_box_mario(o);
            }
            cur_obj_disable_rendering();
            cur_obj_become_intangible();
            break;
        case HELD_THROWN:
            cur_obj_become_tangible();
            cur_obj_enable_rendering();
            o->header.gfx.node.flags &= ~GRAPH_RENDER_INVISIBLE;
            o->oHeldState = HELD_FREE;
            o->oForwardVel = STAGE_BOX_THROW_SPEED;
            o->oVelY = STAGE_BOX_THROW_RISE;
            break;
        case HELD_DROPPED:
            cur_obj_become_tangible();
            cur_obj_enable_rendering();
            cur_obj_get_dropped();
            o->header.gfx.node.flags &= ~GRAPH_RENDER_INVISIBLE;
            o->oHeldState = HELD_FREE;
            break;
    }
    o->oInteractStatus = 0;
}

/* Its colour: the box's display list in its environment colour (in Mario's hands too: the held object's) */
Gfx *geo_stage_box(s32 callContext, struct GraphNode *node, UNUSED void *context) {
    if (callContext != GEO_CONTEXT_RENDER) return NULL;
    struct Object *o = gCurGraphNodeHeldObject ? gCurGraphNodeHeldObject->objNode : (struct Object *) gCurGraphNodeObject;
    struct GraphNodeGenerated *generated = (struct GraphNodeGenerated *) node;
    generated->fnNode.node.flags = (LAYER_OPAQUE << 8) | (generated->fnNode.node.flags & 0xFF);
    Gfx *list = alloc_display_list(3 * sizeof(Gfx));
    if (!list) return NULL;
    u32 rgb = o ? (u32) o->oBehParams : 0xFFFFFF;
    gDPSetEnvColor(&list[0], (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF, 255);
    gSPDisplayList(&list[1], stage_disc_dl_box);
    gSPEndDisplayList(&list[2]);
    return list;
}

/* The picture's boxes on the disc (bhvStageMosaic's one step, where the stage's level script puts it) */
void stage_mosaic_lay(void) {
    struct Object *o = gCurrentObject;
    for (int i = 0; i < STAGE_MOSAIC_BOXES; i++) {
        float x = (stage_mosaic[i].column - (STAGE_MOSAIC_WIDTH - 1) / 2.f) * STAGE_MOSAIC_SPACING;
        float z = STAGE_MOSAIC_Z + (stage_mosaic[i].row - (STAGE_MOSAIC_HEIGHT - 1) / 2.f) * STAGE_MOSAIC_SPACING;
        struct Object *box = spawn_object_abs_with_rot(o, 0, MODEL_STAGE_BOX, bhvStageBox, (s16) x, 0, (s16) z, 0, 0, 0);
        if (!box) break;
        box->oBehParams = (stage_mosaic[i].r << 16) | (stage_mosaic[i].g << 8) | stage_mosaic[i].b;
    }
}

/* How many NPC Marios there are (for tests) */
int stage_npcs(void) { return unity_marios_npcs(); }

/* How many Marios there are on the stage, Mario too, as the HUD shows it: the Mario head, an X and the number, in the
 * middle of the screen's bottom (render_hud: none of the HUD's own is there). The count last shown, for tests */
#define STAGE_HUD_Y 16
static int stage_hud_shown;
int stage_hud_count(void) { return stage_hud_shown; }
static int stage_here(void) { return gCurrLevelNum == LEVEL_CASTLE_GROUNDS && gCurrAreaIndex == 2; }
void stage_hud(void) {
    stage_hud_shown = 0;
    if (!stage_here() || !gMarioObject) return;
    int count = 1 + unity_marios_count(0) + unity_marios_count(1);
    int digits = count >= 100 ? 3 : count >= 10 ? 2 : 1;
    int x = SCREEN_WIDTH / 2 - (32 + 12 * digits) / 2; /* (the head and the X 16 each, a digit 12, as the lives) */
    print_text(x, STAGE_HUD_Y, ",");      /* 'Mario Head' glyph */
    print_text(x + 16, STAGE_HUD_Y, "*"); /* 'X' glyph */
    print_text_fmt_int(x + 32, STAGE_HUD_Y, "%d", count);
    stage_hud_shown = count;
}

/* How many boxes the picture has, and how many are on the stage now (for tests) */
int stage_mosaic_boxes(void) { return STAGE_MOSAIC_BOXES; }

int stage_boxes(void) {
    int n = 0;
    const BehaviorScript *behavior = segmented_to_virtual(bhvStageBox);
    for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
         b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next)
        if (b->behavior == behavior && (b->activeFlags & ACTIVE_FLAG_ACTIVE)) n++;
    return n;
}
