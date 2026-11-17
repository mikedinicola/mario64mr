/* The disc stage (Castle Grounds' area 2: stage_disc.inc.c): its boxes. Included after unity_marios.inc.h (in
 * surface_load.c).
 *
 * - A box (bhvStageBox) is picked up, carried and thrown as the game's small cork box is (Mario's own grab and throw),
 *   but never breaks nor goes away: thrown off the disc's edge it bounces back onto it, and it slides to a stop.
 * - It's drawn in a colour of its own (its oBehParams, 0xRRGGBB: geo_stage_box).
 * - Arriving on the stage, the boxes lie on the disc as a picture, one a pixel (bhvStageMosaic, stage_mosaic.inc.h from
 *   mosaic.png, yours in stage/local/ else stage/'s placeholder, made by stage_gen.py), the picture's top furthest
 *   from the stage's pipe. */

#include "levels/castle_grounds/header.h"
#include "game/memory.h"
#include "game/rendering_graph_node.h"
#include "audio/external.h"
#include "game/spawn_sound.h"
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
