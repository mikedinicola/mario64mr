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
 *   over to Mario, now and then jumps, and keeps away from the edge. While there's room for more, most of the time it
 *   goes for a box never picked up, lifts it (another Mario hops out), carries it a little way and throws it; once
 *   there are UNITY_NPC_MARIOS of them, or no such box is left, none does. They're gone as the extra Marios are, when
 *   Mario leaves the stage.
 * - How many Marios there are (Mario too) is counted at the bottom of the screen, in the HUD's own letters
 *   (stage_hud, after the rest of the HUD).
 * - Marios roll each other. B with another Mario just in front, standing (Mario, or an NPC that means to): he leans
 *   over it, hands out and down, and rolls it along ahead of him as he would a barrel (ACT_STAGE_ROLL, steered by
 *   the stick, as long as B is held). The one rolled lies down and tumbles over and over (stage_tumble_step); let go
 *   (B let up, or a jump), it tumbles on, slowing, knocks over any Mario it rolls into to tumble on too, rolls back
 *   off the rim rather than over it, and gets up again once it stops. Only the other Marios are rolled, not yours.
 * - The disc tilts (bhvStageDisc: an object, its collision loaded as it turns). D-pad up turns tilting on and off
 *   (the game has no other use for it); on, the disc leans as you tilt your controller (sm64unity_stage_tilt, from the
 *   host: forward and right, as the stick is, the way the camera looks), up to STAGE_TILT_MOST; off, it eases level.
 *   Everything on it rides it as it turns (Mario by the game's own platform code, the other Marios, the boxes and the
 *   stage's pipe here), and boxes and tumbling Marios slide and roll downhill.
 * - The disc changes shape, its top a grid of heights (stage_disc_rebuild: its mesh and collision made again as they
 *   change). D-pad right and left: the next and the one before of a hill, a valley, dunes, a pass and flat again,
 *   each eased into over 3 seconds; D-pad down: a pizza, its crust a lip at the rim, its picture swapped in halfway
 *   (and down again: back as it was). Everything standing on it is lifted or lowered with it. Its pictures, the
 *   disc's and the pizza's, are textures in base.zip (stage_gen.py: disc.png, pizza.png, yours in stage/local/ else
 *   stage/'s placeholders). */

#include "levels/castle_grounds/header.h"
#include "game/memory.h"
#include "game/rendering_graph_node.h"
#include "audio/external.h"
#include "game/sound_init.h"
#include "seq_ids.h"
#include "game/spawn_sound.h"
#include "game/print.h"
#include "game/level_update.h"
#include "game/mario_step.h"
#include "behavior_data.h"
extern s16 unity_stick_yaw(s16 camera_yaw); /* (unity_mr.c: the stick's way, the camera's or, out in the room, yours) */
#include "pc/stage_mosaic.inc.h"

/* (obj_behaviors.c's own, as its objects step: on the floor, into a wall) */
extern s16 object_step(void);
#define STAGE_COL_GROUNDED (1 << 0)
#define STAGE_COL_HIT_WALL (1 << 1)

/* The pixels' spacing on the disc, game units (a box is 100 across), and where the picture's middle is */
#define STAGE_MOSAIC_SPACING 110.f /* (each a box across, touching: stage_disc.inc.c's STAGE_BOX_HALF twice) */
#define STAGE_MOSAIC_Z -300.f
/* Thrown: how fast it flies off, and how quickly it stops sliding on the disc */
#define STAGE_BOX_THROW_SPEED 40.f
#define STAGE_BOX_THROW_RISE 20.f
#define STAGE_BOX_GROUND_FRICTION 0.85f
#define STAGE_BOX_SLIDE_GHOST 3.f
/* An NPC Mario: where on the disc it wanders to (within this of its middle), past where it turns back to the
 * middle, how near it runs up to Mario, how fast it walks (the stick's tilt, of 64), how often it jumps */
#define STAGE_NPC_ROAM 2300.f
#define STAGE_NPC_SAFE 2600.f
#define STAGE_NPC_NEAR_MARIO 350.f
#define STAGE_NPC_WALK 48.f
#define STAGE_NPC_JUMP_ONE_IN 200
/* Rolling one: how near in front it must be (and how far round from straight ahead), how fast he rolls it at
 * most, how quickly he turns, how far ahead of him it tumbles, how hard a let go sends it on, how far he leans */
#define STAGE_ROLL_REACH 170.f
#define STAGE_ROLL_ANGLE 0x2800
#define STAGE_ROLL_SPEED 16.f
#define STAGE_ROLL_TURN 0x280
#define STAGE_ROLL_GAP 95.f
#define STAGE_ROLL_PUSH 10.f
#define STAGE_ROLL_LEAN 0x1C00
/* Tumbling: lying as he dives (MARIO_ANIM_DIVE: his length along the way he faces, its line this far up and ahead of
 * his feet), across the way he's rolled, turning over about that line, as round as he is (how high off the ground it
 * is); how quickly it slows, below what it stops, how near it knocks another over, the rim it rolls back off */
#define STAGE_TUMBLE_AXIS_UP 30.f
#define STAGE_TUMBLE_AXIS_AHEAD 30.f
#define STAGE_TUMBLE_RADIUS 35.f
#define STAGE_TUMBLE_SLOWING 0.985f
#define STAGE_TUMBLE_DRAG 0.25f
#define STAGE_TUMBLE_STOP 2.f
#define STAGE_TUMBLE_HIT 90.f
#define STAGE_TUMBLE_RIM 2900.f
/* What the NPCs are for rolling each other: how near they look for one, how long they roll it */
#define STAGE_NPC_ROLL_LOOK 1200.f
#define STAGE_NPC_ROLL_ONE_IN 4
#define STAGE_NPC_BOX_IN_FOUR 3 /* (while there's room for more Marios: how many in four go for a box) */
#define STAGE_NPC_GRAB_REACH 95.f /* (touching it: its radius and a Mario's) */
/* Tilting: how far it leans at most, how quickly it turns, how hard things slide down it */
#define STAGE_TILT_MOST 0x1000
#define STAGE_TILT_FOLLOW 0.5f /* (each step the disc turns this much of the way to the lean wanted...) */
#define STAGE_TILT_RATE 0x300 /* (...but no faster than this a step: 4.2 degrees) */
#define STAGE_SLOPE_PULL 8.f

static struct ObjectHitbox stage_box_hitbox = {
    /* interactType:      */ INTERACT_GRABBABLE,
    /* downOffset:        */ 0,
    /* damageOrCoinValue: */ 0,
    /* health:            */ 1,
    /* numLootCoins:      */ 0,
    /* radius:            */ 60, /* (the box's own size, 110 across: laid out touching, they still leave room) */
    /* height:            */ 110,
    /* hurtboxRadius:     */ 60,
    /* hurtboxHeight:     */ 110,
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
    struct Object *by = o->oHeldState == HELD_HELD && o->parentObj ? o->parentObj : gMarioObject; /* (who picked it up) */
    s16 yaw = by ? atan2s(by->oPosZ - z, by->oPosX - x) : 0; /* (facing him) */
    struct Surface *floor;
    float y = find_floor(x, 4000.f, z, &floor); /* (the disc there, however it leans) */
    if (!floor) return 0;
    struct UnityMario *u = unity_marios_make(x, y, z, yaw, 1);
    if (!u) return 0;
    u->m.action = ACT_JUMP; /* (it hops out) */
    u->m.vel[1] = 42.f;
    u->brain.mode = 0;
    u->brain.timer = 30;
    play_sound(SOUND_GENERAL_COIN, gDefaultSoundArgs);
    return 1;
}

/* Is Mario on the stage? */
static int stage_here(void) { return gCurrLevelNum == LEVEL_CASTLE_GROUNDS && gCurrAreaIndex == 2; }
/* The Marios' voices here, how much higher (as Mario 128's were: 1.5, a fifth up), for the sound bank of Mario's
 * voice (patch_sm64ex.py: external.c's get_sound_freq_scale) */
#define STAGE_VOICE_PITCH 1.5f
f32 stage_voice_pitch(void) { return stage_here() ? STAGE_VOICE_PITCH : 1.0f; }

/* Rolling: who's rolling it, and who it is */
#define ACT_STAGE_ROLL 0x0000047E /* (0x07E | ACT_FLAG_MOVING) rolling another Mario along: stage_act_roll */
#define ACT_STAGE_TUMBLE 0x0002047F /* (0x07F | ACT_FLAG_MOVING | ACT_FLAG_INVULNERABLE) rolled, tumbling: the extra
                                       Marios' only (stage_tumble_step, in place of the Mario code) */
#define ACT_STAGE_SIT 0x0C00021E /* (0x01E | ACT_FLAG_STATIONARY | ACT_FLAG_ALLOW_FIRST_PERSON | ACT_FLAG_PAUSE_EXIT) sat
                                    down a while: stage_act_sit */
#define ACT_STAGE_WAVE 0x0C00021F /* (0x01F | the same) waving at you: stage_act_wave */
static int stage_rolls_started, stage_tumbles_knocked;
static int stage_tumble_way(void);
static struct UnityMario *stage_rolled_by(struct MarioState *m) {
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
        struct UnityMario *t = &unity_marios[i];
        if (t->obj && t->tumbling && t->tumble.by == m) return t;
    }
    return NULL;
}
static float stage_distance(float ax, float az, float bx, float bz) { return sqrtf((ax - bx) * (ax - bx) + (az - bz) * (az - bz)); }
static s16 stage_turn_toward(s16 from, s16 to, s16 most) {
    s16 d = (s16) (to - from);
    return (s16) (from + (d > most ? most : d < -most ? -most : d));
}
/* Can it be rolled (on its feet, not tumbling, nor rolling one), or roll one (and its hands free)? */
static int stage_rollable(struct UnityMario *t) {
    return t->obj && !t->tumbling && !t->lost && !t->m.heldObj && !(t->m.action & ACT_FLAG_AIR) && t->m.action != ACT_STAGE_ROLL
        && !(t->m.action & ACT_FLAG_INTANGIBLE) && t->m.floor;
}
static int stage_can_roll(struct MarioState *m) {
    u32 a = m->action;
    return !m->heldObj && (a == ACT_IDLE || a == ACT_WALKING || a == ACT_DECELERATING || a == ACT_PANTING
                           || a == ACT_BRAKING || a == ACT_STANDING_AGAINST_WALL || a == ACT_BRAKING_STOP);
}
/* Tumbling free, at speed, along dir */
static void stage_tumble_start(struct UnityMario *t, struct MarioState *by, float speed, s16 dir) {
    if (!t->tumbling) t->tumble.spin = 0;
    t->tumbling = 1;
    t->tumble.by = by;
    t->tumble.speed = speed;
    t->tumble.dir = dir;
    t->m.action = ACT_STAGE_TUMBLE;
    t->m.forwardVel = 0.f;
    vec3f_set(t->m.vel, 0.f, 0.f, 0.f);
    t->m.heldObj = NULL;
}
/* The one just in front of m it would roll, if any */
static struct UnityMario *stage_roll_target(struct MarioState *m) {
    struct UnityMario *best = NULL;
    float nearest = STAGE_ROLL_REACH;
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
        struct UnityMario *t = &unity_marios[i];
        if (&t->m == m || !stage_rollable(t)) continue;
        float dx = t->m.pos[0] - m->pos[0], dz = t->m.pos[2] - m->pos[2], d = sqrtf(dx * dx + dz * dz);
        s16 off = (s16) (atan2s(dz, dx) - m->faceAngle[1]);
        if (d < nearest && fabsf(t->m.pos[1] - m->pos[1]) < 80.f && off < STAGE_ROLL_ANGLE && off > -STAGE_ROLL_ANGLE) {
            nearest = d;
            best = t;
        }
    }
    return best;
}
/* m starts rolling the one in front of it, if there's one. 1 if so */
static int stage_roll_start(struct MarioState *m) {
    if (!stage_can_roll(m)) return 0;
    struct UnityMario *t = stage_roll_target(m);
    if (!t) return 0;
    stage_tumble_start(t, m, 0.f, m->faceAngle[1]);
    play_sound(SOUND_MARIO_WHOA, t->obj->header.gfx.cameraToObject);
    set_mario_action(m, ACT_STAGE_ROLL, 0);
    m->forwardVel = m->forwardVel > STAGE_ROLL_SPEED ? STAGE_ROLL_SPEED : m->forwardVel;
    stage_rolls_started++;
    return 1;
}
/* Let go of it: it tumbles on, ahead (or back off the rim) */
static void stage_roll_let_go(struct UnityMario *t, struct MarioState *by, float push) {
    if (!t || t->tumble.by != by) return;
    t->tumble.by = NULL;
    t->tumble.speed = (by->forwardVel > 0.f ? by->forwardVel : 0.f) + push;
}
/* Where it's rolled to: just ahead of him, turned over by as far as it went */
static void stage_roll_carry(struct UnityMario *t, struct MarioState *by) {
    float x = by->pos[0] + STAGE_ROLL_GAP * sins(by->faceAngle[1]), z = by->pos[2] + STAGE_ROLL_GAP * coss(by->faceAngle[1]);
    struct Surface *floor;
    float y = find_floor(x, by->pos[1] + 100.f, z, &floor);
    if (!floor || stage_distance(x, z, 0.f, 0.f) > STAGE_TUMBLE_RIM) { /* (at the rim: it rolls back off it) */
        stage_roll_let_go(t, by, 0.f);
        t->tumble.dir = (s16) (by->faceAngle[1] + 0x8000);
        t->tumble.speed = 6.f;
        return;
    }
    float moved = stage_distance(x, z, t->m.pos[0], t->m.pos[2]);
    t->tumble.spin += (s16) (moved / STAGE_TUMBLE_RADIUS * 0x10000 / (2 * M_PI)) * stage_tumble_way();
    t->tumble.dir = by->faceAngle[1];
    t->m.pos[0] = x; t->m.pos[1] = y; t->m.pos[2] = z;
    t->m.floor = floor; t->m.floorHeight = y;
}

/* (x, y, z) of a Mario's own, turned as he's drawn turned by angle (geo_process_object's rotation) */
static void stage_turned(Vec3s angle, float x, float y, float z, Vec3f out) {
    Mat4 turn;
    Vec3f zero = { 0.f, 0.f, 0.f };
    mtxf_rotate_zxy_and_translate(turn, zero, angle);
    for (int j = 0; j < 3; j++) out[j] = x * turn[0][j] + y * turn[1][j] + z * turn[2][j];
}
/* Which way the spin turns him over forwards (his top on ahead, the way he's rolled): 1 or -1 */
static int stage_tumble_way(void) {
    static int way;
    if (!way) {
        Vec3s angle = { 0, 0x4000, 0x400 }; /* (rolled along +z, so lying along +x: turned a little over) */
        Vec3f top;
        stage_turned(angle, 0.f, 1.f, 0.f, top);
        way = top[2] > 0.f ? 1 : -1;
    }
    return way;
}

/* Mario's own action, rolling one along (mario_execute_moving_action) */
s32 stage_act_roll(struct MarioState *m) {
    struct UnityMario *t = stage_rolled_by(m);
    if (!t) return set_mario_action(m, ACT_IDLE, 0);
    if (m->input & INPUT_A_PRESSED) {
        stage_roll_let_go(t, m, STAGE_ROLL_PUSH);
        return set_jumping_action(m, ACT_JUMP, 0);
    }
    if (!(m->controller->buttonDown & B_BUTTON)) {
        stage_roll_let_go(t, m, STAGE_ROLL_PUSH);
        return set_mario_action(m, m->forwardVel > 2.f ? ACT_DECELERATING : ACT_IDLE, 0);
    }
    float target = (m->input & INPUT_NONZERO_ANALOG) ? m->intendedMag / 32.f * STAGE_ROLL_SPEED : 0.f;
    float v = m->forwardVel;
    v = v < target ? (v + 1.f > target ? target : v + 1.f) : (v - 2.f < target ? target : v - 2.f);
    if (m->input & INPUT_NONZERO_ANALOG) m->faceAngle[1] = stage_turn_toward(m->faceAngle[1], m->intendedYaw, STAGE_ROLL_TURN);
    mario_set_forward_vel(m, v);
    s32 step = perform_ground_step(m);
    if (step == GROUND_STEP_LEFT_GROUND) {
        stage_roll_let_go(t, m, 0.f);
        return set_mario_action(m, ACT_FREEFALL, 0);
    }
    if (step == GROUND_STEP_HIT_WALL) mario_set_forward_vel(m, 0.f);
    set_mario_anim_with_accel(m, MARIO_ANIM_PUSHING, (s32) (m->forwardVel / 4.f * 0x10000));
    m->marioBodyState->handState = MARIO_HAND_OPEN;
    m->marioBodyState->torsoAngle[0] = STAGE_ROLL_LEAN; /* (leaning over it: geo_mario_tilt_torso, let for this) */
    m->marioBodyState->torsoAngle[1] = m->marioBodyState->torsoAngle[2] = 0;
    stage_roll_carry(t, m);
    return FALSE;
}
/* (never Mario's own: ACT_STAGE_TUMBLE is the extra Marios', who run no Mario code while in it) */
s32 stage_act_tumble(struct MarioState *m) { return set_mario_action(m, ACT_IDLE, 0); }

/* Sitting a while, or waving at you (an NPC's, now and then: mario_execute_stationary_action). Either is left for
 * whatever its controller does next: sitting, it gets up first */
s32 check_common_idle_cancels(struct MarioState *m); /* (mario_actions_stationary.c) */
#define STAGE_STAND_INPUTS (INPUT_NONZERO_ANALOG | INPUT_A_PRESSED | INPUT_B_PRESSED | INPUT_Z_PRESSED | INPUT_FIRST_PERSON)
#define STAGE_WAVE_TURN 0x400
void unity_viewer(Vec3f out); /* (unity_mr.c) */
s32 stage_act_sit(struct MarioState *m) {
    if (m->input & INPUT_OFF_FLOOR) return set_mario_action(m, ACT_FREEFALL, 0);
    if (m->input & INPUT_ABOVE_SLIDE) return set_mario_action(m, ACT_BEGIN_SLIDING, 0);
    if (m->input & STAGE_STAND_INPUTS) return set_mario_action(m, ACT_WAKING_UP, 0);
    stationary_ground_step(m);
    set_mario_animation(m, MARIO_ANIM_START_SLEEP_SITTING); /* (sitting down, then sat: it holds its last frame) */
    if (m->actionTimer++ == 15) play_sound(m->terrainSoundAddend + SOUND_ACTION_TERRAIN_BODY_HIT_GROUND, m->marioObj->header.gfx.cameraToObject);
    return FALSE;
}
s32 stage_act_wave(struct MarioState *m) {
    if (m->input & (STAGE_STAND_INPUTS | INPUT_OFF_FLOOR | INPUT_ABOVE_SLIDE)) return check_common_idle_cancels(m);
    Vec3f you;
    unity_viewer(you);
    m->faceAngle[1] = stage_turn_toward(m->faceAngle[1], atan2s(you[2] - m->pos[2], you[0] - m->pos[0]), STAGE_WAVE_TURN);
    stationary_ground_step(m);
    set_mario_animation(m, MARIO_ANIM_CREDITS_WAVING);
    m->marioBodyState->handState = MARIO_HAND_RIGHT_OPEN;
    return FALSE;
}

/* A rolled Mario's step: rolled along, or tumbling on, or getting up */
static void stage_tumble_step(struct UnityMario *u) {
    struct MarioState *m = &u->m;
    struct Object *o = u->obj;
    if (u->tumble.by && u->tumble.by->action != ACT_STAGE_ROLL) u->tumble.by = NULL; /* (he stopped rolling it) */
    if (!u->tumble.by) {
        float speed = u->tumble.speed;
        /* Stopped: it turns on over onto its front (as it lies in a dive), then gets up from it, where it's drawn */
        if (speed < STAGE_TUMBLE_STOP) {
            s16 left = (s16) (0 - u->tumble.spin) * stage_tumble_way();
            if (left > 0x600 || left < 0) u->tumble.spin += 0x600 * stage_tumble_way();
            else {
                u->tumbling = 0;
                m->faceAngle[1] = (s16) (u->tumble.dir + 0x4000); /* (his head's way) */
                m->faceAngle[0] = m->faceAngle[2] = 0;
                m->pos[0] -= STAGE_TUMBLE_AXIS_AHEAD * sins(m->faceAngle[1]);
                m->pos[2] -= STAGE_TUMBLE_AXIS_AHEAD * coss(m->faceAngle[1]);
                vec3f_copy(o->header.gfx.pos, m->pos);
                vec3s_set(o->header.gfx.angle, 0, m->faceAngle[1], 0);
                set_mario_action(m, ACT_STOMACH_SLIDE_STOP, 0);
                return;
            }
        } else {
            float x = m->pos[0] + speed * sins(u->tumble.dir), z = m->pos[2] + speed * coss(u->tumble.dir);
            struct Surface *floor;
            float y = find_floor(x, m->pos[1] + 100.f, z, &floor);
            if (!floor || stage_distance(x, z, 0.f, 0.f) > STAGE_TUMBLE_RIM) { /* (the rim: back off it) */
                u->tumble.dir += 0x8000;
                u->tumble.speed *= 0.6f;
            } else {
                m->pos[0] = x; m->pos[1] = y; m->pos[2] = z;
                m->floor = floor; m->floorHeight = y;
                u->tumble.spin += (s16) (speed / STAGE_TUMBLE_RADIUS * 0x10000 / (2 * M_PI)) * stage_tumble_way();
                u->tumble.speed = speed * STAGE_TUMBLE_SLOWING - STAGE_TUMBLE_DRAG;
                if (floor) /* (downhill, it rolls on faster; uphill, it slows) */
                    u->tumble.speed += STAGE_SLOPE_PULL / 4.f
                        * (floor->normal.x * sins(u->tumble.dir) + floor->normal.z * coss(u->tumble.dir));
                /* Into another Mario: that one's knocked over to tumble on too, and this one slows */
                for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
                    struct UnityMario *t = &unity_marios[i];
                    if (t == u || !stage_rollable(t)) continue;
                    if (stage_distance(t->m.pos[0], t->m.pos[2], x, z) < STAGE_TUMBLE_HIT) {
                        stage_tumble_start(t, NULL, speed * 0.8f, u->tumble.dir);
                        play_sound(SOUND_MARIO_WHOA, t->obj->header.gfx.cameraToObject);
                        u->tumble.speed *= 0.5f;
                        stage_tumbles_knocked++;
                    }
                }
            }
        }
    }
    /* Drawn lying across the way it rolls (facing a quarter turn round from it), turned over about its length by its
     * spin, that line where it is, as high as he's round */
    m->action = ACT_STAGE_TUMBLE;
    vec3f_set(m->vel, 0.f, 0.f, 0.f);
    m->forwardVel = 0.f;
    m->faceAngle[1] = u->tumble.dir;
    set_mario_animation(m, MARIO_ANIM_DIVE);
    m->marioBodyState->eyeState = MARIO_EYES_DEAD;
    m->marioBodyState->handState = MARIO_HAND_OPEN;
    m->marioBodyState->action = m->action;
    vec3s_set(m->marioBodyState->torsoAngle, 0, 0, 0);
    Vec3s angle = { 0, (s16) (u->tumble.dir + 0x4000), u->tumble.spin };
    Vec3f line;
    stage_turned(angle, 0.f, STAGE_TUMBLE_AXIS_UP, STAGE_TUMBLE_AXIS_AHEAD, line);
    o->header.gfx.throwMatrix = NULL;
    o->header.gfx.pos[0] = m->pos[0] - line[0];
    o->header.gfx.pos[1] = m->pos[1] + STAGE_TUMBLE_RADIUS - line[1];
    o->header.gfx.pos[2] = m->pos[2] - line[2];
    vec3s_copy(o->header.gfx.angle, angle);
}

/* ---- The disc's shape ---- */

/* Its top: a grid of rings about its middle, STAGE_DISC_SIDES points round each; its rim a wall STAGE_DISC_THICKNESS
 * deep, all the way round. Every point's height is its shape's (stage_shape_height); the mesh drawn and the collision
 * are made again from them whenever they change (stage_disc_rebuild) */
#define STAGE_DISC_RADIUS 3000.f
#define STAGE_DISC_THICKNESS 300.f
#define STAGE_DISC_RINGS 10
#define STAGE_DISC_SIDES 40
#define STAGE_DISC_POINTS (1 + STAGE_DISC_RINGS * STAGE_DISC_SIDES) /* (the middle, then ring by ring; then the rim's
                                                                       bottom, STAGE_DISC_SIDES more) */
#define STAGE_DISC_TOP_TRIS (STAGE_DISC_SIDES * (2 * STAGE_DISC_RINGS - 1))
#define STAGE_DISC_TRIS (STAGE_DISC_TOP_TRIS + 2 * STAGE_DISC_SIDES)
#define STAGE_DISC_BATCH 10 /* (triangles a vertex load: each its own three vertices) */
#define STAGE_MORPH_STEPS 90 /* (3 seconds from one shape to the next) */
enum { STAGE_FLAT, STAGE_HILL, STAGE_VALLEY, STAGE_DUNES, STAGE_PASS, STAGE_SHAPES, STAGE_PIZZA = STAGE_SHAPES };

/* Its pictures: textures by name, from base.zip (stage_gen.PICTURES: install_mario64mr.py packs them there), the
 * picture spanning the disc as STAGE_DISC_TEXELS square (any size: it's scaled to fit) */
static const u8 stage_disc_texture[] = "levels/castle_grounds/stage_disc.rgba32";
static const u8 stage_pizza_texture[] = "levels/castle_grounds/stage_pizza.rgba32";
#define STAGE_DISC_TEXELS 64
static const u8 stage_disc_wall[2][3] = { { 0x9C, 0x7A, 0x52 }, { 0xB8, 0x74, 0x34 } }; /* (its rim's: disc, pizza) */

static struct {
    int ready;
    int shape, last_shape;           /* the shape it is or is becoming, and the last before the pizza */
    int picture, from_picture, to_picture; /* (1: the pizza's) */
    int step;                        /* into the change, of STAGE_MORPH_STEPS (there: it's done) */
    float from[STAGE_DISC_POINTS], to[STAGE_DISC_POINTS], now[STAGE_DISC_POINTS], was[STAGE_DISC_POINTS];
} stage_disc;
static float stage_disc_xz[STAGE_DISC_POINTS + STAGE_DISC_SIDES][2];
static u16 stage_disc_tri[STAGE_DISC_TRIS][3];
static Vtx stage_disc_vtx[3 * STAGE_DISC_TRIS];
static Gfx stage_disc_gfx[24 + 6 * (STAGE_DISC_TRIS / STAGE_DISC_BATCH + 2)];
static s16 stage_disc_collision[8 + 3 * (STAGE_DISC_POINTS + STAGE_DISC_SIDES) + 3 * STAGE_DISC_TRIS];

/* How high a shape is at (x, z) on the disc (its own space: its middle at 0 0) */
static float stage_shape_height(int shape, float x, float z) {
    float r = sqrtf(x * x + z * z) / STAGE_DISC_RADIUS;
    if (r > 1.f) r = 1.f;
    switch (shape) {
        case STAGE_HILL: return 900.f * (1.f + cosf((float) M_PI * r)) / 2.f;    /* (a round hill, its foot the rim) */
        case STAGE_VALLEY: return 800.f * r * r;                                 /* (a bowl) */
        case STAGE_DUNES: return 120.f * (1.f - cosf(4.f * (float) M_PI * r));   /* (two rings of dunes) */
        case STAGE_PASS: return 500.f * (x * x - z * z) / (STAGE_DISC_RADIUS * STAGE_DISC_RADIUS); /* (a saddle) */
        case STAGE_PIZZA: {                                                      /* (its crust, a lip at the rim) */
            float s = (r - 0.86f) / 0.1f;
            s = s < 0.f ? 0.f : s > 1.f ? 1.f : s;
            return 70.f * s * s * (3.f - 2.f * s);
        }
        default: return 0.f;
    }
}

static int stage_disc_point(int ring, int side) {
    return ring ? 1 + (ring - 1) * STAGE_DISC_SIDES + side % STAGE_DISC_SIDES : 0;
}
/* The game's own floor normal's y (surface_load.c), of a triangle by its points: above 0, facing up */
static float stage_disc_up(int a, int b, int c) {
    float (*p)[2] = stage_disc_xz;
    return (p[b][1] - p[a][1]) * (p[c][0] - p[b][0]) - (p[b][0] - p[a][0]) * (p[c][1] - p[b][1]);
}
static void stage_disc_add_floor(int *n, int a, int b, int c) {
    if (stage_disc_up(a, b, c) < 0.f) { int t = b; b = c; c = t; }
    stage_disc_tri[*n][0] = a; stage_disc_tri[*n][1] = b; stage_disc_tri[*n][2] = c;
    (*n)++;
}
/* The triangles: the middle's fan, each ring to the next as two a side (stage_disc_mesh_height finds them so), and
 * the rim's wall facing out */
static void stage_disc_layout(void) {
    for (int ring = 0; ring <= STAGE_DISC_RINGS; ring++)
        for (int side = 0; side < (ring ? STAGE_DISC_SIDES : 1); side++) {
            float a = 2.f * (float) M_PI * side / STAGE_DISC_SIDES, rad = STAGE_DISC_RADIUS * ring / STAGE_DISC_RINGS;
            int p = stage_disc_point(ring, side);
            stage_disc_xz[p][0] = rad * sinf(a); stage_disc_xz[p][1] = rad * cosf(a);
            if (ring == STAGE_DISC_RINGS) {
                stage_disc_xz[STAGE_DISC_POINTS + side][0] = stage_disc_xz[p][0];
                stage_disc_xz[STAGE_DISC_POINTS + side][1] = stage_disc_xz[p][1];
            }
        }
    int n = 0;
    for (int side = 0; side < STAGE_DISC_SIDES; side++)
        stage_disc_add_floor(&n, 0, stage_disc_point(1, side), stage_disc_point(1, side + 1));
    for (int ring = 1; ring < STAGE_DISC_RINGS; ring++)
        for (int side = 0; side < STAGE_DISC_SIDES; side++) {
            int a = stage_disc_point(ring, side), b = stage_disc_point(ring + 1, side);
            int c = stage_disc_point(ring + 1, side + 1), d = stage_disc_point(ring, side + 1);
            stage_disc_add_floor(&n, a, b, c);
            stage_disc_add_floor(&n, a, c, d);
        }
    for (int side = 0; side < STAGE_DISC_SIDES; side++) {
        int top0 = stage_disc_point(STAGE_DISC_RINGS, side), top1 = stage_disc_point(STAGE_DISC_RINGS, side + 1);
        int bottom0 = STAGE_DISC_POINTS + side, bottom1 = STAGE_DISC_POINTS + (side + 1) % STAGE_DISC_SIDES;
        /* (facing out: the game's wall normal of top0 top1 bottom1, along x z, the way out from the middle; if not,
         * turned round) */
        float (*p)[2] = stage_disc_xz;
        float a[3] = { p[top0][0], 0.f, p[top0][1] }, b[3] = { p[top1][0], 0.f, p[top1][1] };
        float c[3] = { p[bottom1][0], -STAGE_DISC_THICKNESS, p[bottom1][1] };
        float nx = (b[1] - a[1]) * (c[2] - b[2]) - (b[2] - a[2]) * (c[1] - b[1]);
        float nz = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
        int flip = nx * (a[0] + b[0]) + nz * (a[2] + b[2]) < 0.f;
        u16 quad[2][3] = { { top0, top1, bottom1 }, { top0, bottom1, bottom0 } };
        for (int t = 0; t < 2; t++, n++) {
            stage_disc_tri[n][0] = quad[t][0];
            stage_disc_tri[n][1] = flip ? quad[t][2] : quad[t][1];
            stage_disc_tri[n][2] = flip ? quad[t][1] : quad[t][2];
        }
    }
}

/* A point's height now (the rim's bottom, under the top's) */
static float stage_disc_y(int p) {
    return p < STAGE_DISC_POINTS ? stage_disc.now[p]
                                 : stage_disc.now[stage_disc_point(STAGE_DISC_RINGS, p - STAGE_DISC_POINTS)] - STAGE_DISC_THICKNESS;
}

/* Its mesh and collision, from its heights now */
static void stage_disc_rebuild(void) {
    /* The top's shading: each point's normal (its triangles' together), lit from a light of its own */
    static float normal[STAGE_DISC_POINTS][3];
    bzero(normal, sizeof(normal));
    for (int t = 0; t < STAGE_DISC_TOP_TRIS; t++) {
        u16 *k = stage_disc_tri[t];
        float e1[3] = { stage_disc_xz[k[1]][0] - stage_disc_xz[k[0]][0], stage_disc_y(k[1]) - stage_disc_y(k[0]), stage_disc_xz[k[1]][1] - stage_disc_xz[k[0]][1] };
        float e2[3] = { stage_disc_xz[k[2]][0] - stage_disc_xz[k[0]][0], stage_disc_y(k[2]) - stage_disc_y(k[0]), stage_disc_xz[k[2]][1] - stage_disc_xz[k[0]][1] };
        float c[3] = { e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
        float s = c[1] < 0.f ? -1.f : 1.f;
        for (int j = 0; j < 3; j++) for (int i = 0; i < 3; i++) normal[k[j]][i] += s * c[i];
    }
    const float light[3] = { -0.33f, 0.80f, 0.50f }; /* (about unit) */
    const u8 *wall = stage_disc_wall[stage_disc.picture];
    for (int t = 0; t < STAGE_DISC_TRIS; t++)
        for (int j = 0; j < 3; j++) {
            int p = stage_disc_tri[t][j];
            Vtx_t *v = &stage_disc_vtx[3 * t + j].v;
            float x = stage_disc_xz[p][0], z = stage_disc_xz[p][1];
            v->ob[0] = (s16) roundf(x); v->ob[1] = (s16) roundf(stage_disc_y(p)); v->ob[2] = (s16) roundf(z);
            v->flag = 0;
            v->tc[0] = (s16) ((x / STAGE_DISC_RADIUS + 1.f) / 2.f * STAGE_DISC_TEXELS * 32);
            v->tc[1] = (s16) ((z / STAGE_DISC_RADIUS + 1.f) / 2.f * STAGE_DISC_TEXELS * 32);
            v->cn[3] = 0xFF;
            if (t < STAGE_DISC_TOP_TRIS) {
                float *n = normal[p], len = sqrtf(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
                float lit = len > 0.f ? (n[0] * light[0] + n[1] * light[1] + n[2] * light[2]) / len : 1.f;
                u8 shade = (u8) (255.f * (0.55f + 0.45f * (lit > 0.f ? lit : 0.f)));
                v->cn[0] = v->cn[1] = v->cn[2] = shade;
            } else {
                int bottom = p >= STAGE_DISC_POINTS;
                for (int i = 0; i < 3; i++) v->cn[i] = (u8) (bottom ? wall[i] * 3 / 4 : wall[i]);
            }
        }

    /* Drawn: the top with its picture, shaded; the rim plain */
    Gfx *g = stage_disc_gfx;
    gDPPipeSync(g++);
    gDPSetCombineMode(g++, G_CC_MODULATERGB, G_CC_MODULATERGB);
    gSPClearGeometryMode(g++, G_LIGHTING);
    gSPTexture(g++, 0xFFFF, 0xFFFF, 0, G_TX_RENDERTILE, G_ON);
    gDPLoadTextureBlock(g++, stage_disc.picture ? stage_pizza_texture : stage_disc_texture, G_IM_FMT_RGBA, G_IM_SIZ_32b,
                        STAGE_DISC_TEXELS, STAGE_DISC_TEXELS, 0, G_TX_CLAMP, G_TX_CLAMP, 6, 6, G_TX_NOLOD, G_TX_NOLOD);
    for (int t = 0; t < STAGE_DISC_TRIS; t += STAGE_DISC_BATCH) {
        if (t == STAGE_DISC_TOP_TRIS) {
            gSPTexture(g++, 0xFFFF, 0xFFFF, 0, G_TX_RENDERTILE, G_OFF);
            gDPPipeSync(g++);
            gDPSetCombineMode(g++, G_CC_SHADE, G_CC_SHADE);
        }
        int n = STAGE_DISC_TRIS - t < STAGE_DISC_BATCH ? STAGE_DISC_TRIS - t : STAGE_DISC_BATCH;
        gSPVertex(g++, &stage_disc_vtx[3 * t], 3 * n, 0);
        for (int k = 0; k < n; k += 2) {
            if (k + 1 < n) { gSP2Triangles(g++, 3 * k, 3 * k + 1, 3 * k + 2, 0x0, 3 * k + 3, 3 * k + 4, 3 * k + 5, 0x0); }
            else { gSP1Triangle(g++, 3 * k, 3 * k + 1, 3 * k + 2, 0x0); }
        }
    }
    gDPPipeSync(g++);
    gSPSetGeometryMode(g++, G_LIGHTING);
    gSPEndDisplayList(g++);

    /* Its collision, as level collision data is (the object's own: stage_disc_load_collision) */
    s16 *c = stage_disc_collision;
    *c++ = TERRAIN_LOAD_VERTICES;
    *c++ = STAGE_DISC_POINTS + STAGE_DISC_SIDES;
    for (int p = 0; p < STAGE_DISC_POINTS + STAGE_DISC_SIDES; p++) {
        *c++ = (s16) roundf(stage_disc_xz[p][0]); *c++ = (s16) roundf(stage_disc_y(p)); *c++ = (s16) roundf(stage_disc_xz[p][1]);
    }
    *c++ = SURFACE_DEFAULT;
    *c++ = STAGE_DISC_TRIS;
    for (int t = 0; t < STAGE_DISC_TRIS; t++)
        for (int j = 0; j < 3; j++) *c++ = (s16) stage_disc_tri[t][j];
    *c++ = TERRAIN_LOAD_CONTINUE;
    *c++ = TERRAIN_LOAD_END;
}

/* The disc's collision where it is now (load_object_collision_model's, for more vertices than it holds) */
static void stage_disc_load_collision(struct Object *o) {
    static s16 vertices[3 * (STAGE_DISC_POINTS + STAGE_DISC_SIDES)];
    s16 *data = stage_disc_collision + 1;
    if (!(gTimeStopState & TIME_STOP_ACTIVE)) {
        transform_object_vertices(&data, vertices);
        while (*data != TERRAIN_LOAD_CONTINUE) load_object_surfaces(&data, vertices);
    }
    o->header.gfx.node.flags |= GRAPH_RENDER_ACTIVE;
}

/* How high its top is at (x, z), its own space, by heights h: on the triangle there, as the collision is */
static float stage_disc_mesh_height(const float *h, float x, float z) {
    float ring = sqrtf(x * x + z * z) / STAGE_DISC_RADIUS * STAGE_DISC_RINGS;
    u16 yaw = (u16) atan2s(z, x); /* (the game's way round: its points' too, x by sin and z by cos) */
    int side = (int) ((u32) yaw * STAGE_DISC_SIDES >> 16) % STAGE_DISC_SIDES;
    int k = (int) ring;
    if (k >= STAGE_DISC_RINGS) k = STAGE_DISC_RINGS - 1;
    int tris[2][3], count;
    if (k == 0) {
        tris[0][0] = 0; tris[0][1] = stage_disc_point(1, side); tris[0][2] = stage_disc_point(1, side + 1);
        count = 1;
    } else {
        int pa = stage_disc_point(k, side), pb = stage_disc_point(k + 1, side);
        int pc = stage_disc_point(k + 1, side + 1), pd = stage_disc_point(k, side + 1);
        tris[0][0] = pa; tris[0][1] = pb; tris[0][2] = pc;
        tris[1][0] = pa; tris[1][1] = pc; tris[1][2] = pd;
        count = 2;
    }
    float best = 0.f;
    for (int t = 0; t < count; t++) {
        float (*p)[2] = stage_disc_xz;
        int i0 = tris[t][0], i1 = tris[t][1], i2 = tris[t][2];
        float d = (p[i1][1] - p[i2][1]) * (p[i0][0] - p[i2][0]) + (p[i2][0] - p[i1][0]) * (p[i0][1] - p[i2][1]);
        float w0 = ((p[i1][1] - p[i2][1]) * (x - p[i2][0]) + (p[i2][0] - p[i1][0]) * (z - p[i2][1])) / d;
        float w1 = ((p[i2][1] - p[i0][1]) * (x - p[i2][0]) + (p[i0][0] - p[i2][0]) * (z - p[i2][1])) / d;
        float w2 = 1.f - w0 - w1;
        best = w0 * h[i0] + w1 * h[i1] + w2 * h[i2];
        if (w0 > -1e-3f && w1 > -1e-3f && w2 > -1e-3f) break; /* (in it; else the other) */
    }
    return best;
}

/* p in the disc's own space, the disc turned by angle */
static void stage_disc_local(struct Object *disc, Vec3s angle, Vec3f p, Vec3f local) {
    Mat4 m;
    Vec3f offset = { p[0] - disc->oPosX, p[1] - disc->oPosY, p[2] - disc->oPosZ };
    mtxf_rotate_zxy_and_translate(m, offset, angle);
    linear_mtxf_transpose_mul_vec3f(m, local, offset);
}
/* Standing on the disc, turned by angle, its top heights h (within a few units of its top)? */
static int stage_on_disc_at(struct Object *disc, Vec3s angle, const float *h, Vec3f p) {
    Vec3f local;
    stage_disc_local(disc, angle, p, local);
    if (local[0] * local[0] + local[2] * local[2] > (STAGE_DISC_RADIUS + 30.f) * (STAGE_DISC_RADIUS + 30.f)) return 0;
    return fabsf(local[1] - stage_disc_mesh_height(h, local[0], local[2])) < 10.f;
}
/* Standing on it, before its turn this step? (where it was turned, with its top as it is now) */
static int stage_on_disc(struct Object *disc, Vec3f p) {
    Vec3s was = { (s16) (disc->oFaceAnglePitch - disc->oAngleVelPitch), 0, (s16) (disc->oFaceAngleRoll - disc->oAngleVelRoll) };
    return stage_on_disc_at(disc, was, stage_disc.now, p);
}
/* Something standing on it, lifted or lowered as its top is beneath it this step */
static void stage_disc_lift(struct Object *disc, Vec3f p) {
    Vec3s angle = { (s16) disc->oFaceAnglePitch, 0, (s16) disc->oFaceAngleRoll };
    if (!stage_on_disc_at(disc, angle, stage_disc.was, p)) return;
    Vec3f local, up;
    stage_disc_local(disc, angle, p, local);
    float rise = stage_disc_mesh_height(stage_disc.now, local[0], local[2]) - stage_disc_mesh_height(stage_disc.was, local[0], local[2]);
    stage_turned(angle, 0.f, rise, 0.f, up);
    p[0] += up[0]; p[1] += up[1]; p[2] += up[2];
}

/* Start changing to a shape (from wherever it is, partway through a change or not) */
static void stage_disc_reshape(int shape) {
    if (shape == stage_disc.shape) return;
    memcpy(stage_disc.from, stage_disc.now, sizeof(stage_disc.from));
    for (int p = 0; p < STAGE_DISC_POINTS; p++)
        stage_disc.to[p] = stage_shape_height(shape, stage_disc_xz[p][0], stage_disc_xz[p][1]);
    stage_disc.from_picture = stage_disc.picture;
    stage_disc.to_picture = shape == STAGE_PIZZA;
    stage_disc.shape = shape;
    if (shape != STAGE_PIZZA) stage_disc.last_shape = shape;
    stage_disc.step = 0;
    play_sound(SOUND_GENERAL_BIG_POUND, gDefaultSoundArgs);
}

/* Arriving on the stage: flat, the disc's own picture (bhvStageDisc's init) */
void stage_disc_init(void) {
    stage_disc_layout();
    bzero(&stage_disc, sizeof(stage_disc));
    stage_disc.step = STAGE_MORPH_STEPS;
    stage_disc.ready = 1;
    stage_disc_rebuild();
}

/* A step of a change of shape (before the disc turns): the heights eased from the old shape's to the new's, the
 * picture swapped halfway, and what stands on it lifted or lowered with it */
static void stage_disc_shape_step(struct Object *o) {
    if (stage_disc.step >= STAGE_MORPH_STEPS) return;
    stage_disc.step++;
    float t = (float) stage_disc.step / STAGE_MORPH_STEPS, e = t * t * (3.f - 2.f * t);
    memcpy(stage_disc.was, stage_disc.now, sizeof(stage_disc.was));
    for (int p = 0; p < STAGE_DISC_POINTS; p++)
        stage_disc.now[p] = stage_disc.from[p] + (stage_disc.to[p] - stage_disc.from[p]) * e;
    int picture = e < 0.5f ? stage_disc.from_picture : stage_disc.to_picture;
    if (picture != stage_disc.picture) {
        stage_disc.picture = picture;
        if (picture) play_sound(SOUND_MENU_STAR_SOUND, gDefaultSoundArgs);
    }
    if (gMarioState && gMarioState->marioObj) stage_disc_lift(o, gMarioState->pos);
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
        struct UnityMario *u = &unity_marios[i];
        if (u->obj && (u->obj->activeFlags & ACTIVE_FLAG_ACTIVE)) stage_disc_lift(o, u->m.pos);
    }
    const BehaviorScript *box = segmented_to_virtual(bhvStageBox);
    for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
         b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next) {
        if (b->behavior != box || b->oHeldState != HELD_FREE) continue;
        Vec3f p = { b->oPosX, b->oPosY, b->oPosZ };
        stage_disc_lift(o, p);
        b->oPosX = p[0]; b->oPosY = p[1]; b->oPosZ = p[2];
    }
    stage_disc_rebuild();
}

/* The disc's mesh, as it's shaped now (its model's: stage_disc_model_geo) */
Gfx *geo_stage_disc(s32 callContext, struct GraphNode *node, UNUSED void *context) {
    if (callContext != GEO_CONTEXT_RENDER || !stage_disc.ready) return NULL;
    node->flags = (LAYER_OPAQUE << 8) | (node->flags & 0xFF);
    return stage_disc_gfx;
}

/* (tests) The shape it is or is becoming (STAGE_PIZZA, 5: the pizza); changing still?; the pizza's picture on? */
int stage_disc_shape(void) { return stage_disc.shape; }
int stage_disc_changing(void) { return stage_disc.step < STAGE_MORPH_STEPS; }
int stage_disc_pizza(void) { return stage_disc.picture; }

/* ---- Tilting ---- */

static int stage_tilting;          /* (D-pad up turns it on and off) */
static float stage_tilt_in[2];     /* the controller's lean, from the host: forward and right (radians) */
static struct Object *stage_pipe;  /* the stage's own pipe, on the disc */
#define STAGE_PIPE_Z 2400.f

/* The host's: how the controller leans now (radians: its top forward, away from you; its right side down), as the
 * stick is, the way you look (in a diorama, the host turns it as it turns the stick). 0 0 with none */
EXPORT void sm64unity_stage_tilt(float forward, float right) { stage_tilt_in[0] = forward; stage_tilt_in[1] = right; }
/* Is tilting on? (the host can show it; tests) */
EXPORT int sm64unity_stage_tilting(void) { return stage_tilting && stage_here(); }

/* An angle of the disc's turned towards the one wanted: much of the way at once (it follows the controller closely),
 * no faster than STAGE_TILT_RATE */
static s16 stage_tilt_toward(s16 from, s16 to) {
    int gap = (s16) (to - from), step = (int) (gap * STAGE_TILT_FOLLOW);
    if (step == 0) step = gap; /* (the last bit) */
    if (step > STAGE_TILT_RATE) step = STAGE_TILT_RATE;
    if (step < -STAGE_TILT_RATE) step = -STAGE_TILT_RATE;
    return (s16) (from + step);
}

/* Which way pitch and roll lean the disc's top (+1 or -1): its up turned a little by each */
static void stage_tilt_ways(int *pitch, int *roll) {
    static int p, r;
    if (!p) {
        Vec3f up;
        Vec3s angle = { 0x400, 0, 0 };
        stage_turned(angle, 0.f, 1.f, 0.f, up);
        p = up[2] > 0.f ? 1 : -1; /* (pitch leans its up towards +z, or -z) */
        Vec3s angle2 = { 0, 0, 0x400 };
        stage_turned(angle2, 0.f, 1.f, 0.f, up);
        r = up[0] > 0.f ? 1 : -1;
    }
    *pitch = p; *roll = r;
}
/* Where a point on the disc goes, turned with it this step (as the game's platform code moves Mario) */
static void stage_disc_carry(struct Object *disc, Vec3f p) {
    Mat4 m;
    Vec3f offset = { p[0] - disc->oPosX, p[1] - disc->oPosY, p[2] - disc->oPosZ }, local, moved;
    Vec3s was = { disc->oFaceAnglePitch - disc->oAngleVelPitch, 0, disc->oFaceAngleRoll - disc->oAngleVelRoll };
    Vec3s now = { disc->oFaceAnglePitch, 0, disc->oFaceAngleRoll };
    mtxf_rotate_zxy_and_translate(m, offset, was);
    linear_mtxf_transpose_mul_vec3f(m, local, offset);
    mtxf_rotate_zxy_and_translate(m, offset, now);
    linear_mtxf_mul_vec3f(m, moved, local);
    p[0] = disc->oPosX + moved[0]; p[1] = disc->oPosY + moved[1]; p[2] = disc->oPosZ + moved[2];
}
/* The disc's step (bhvStageDisc, in the surface list: before Mario's platform displacement and everyone's own step):
 * its shape changes on, if it's changing; it leans towards the controller's lean, or back level; what's on it rides
 * along; its collision where it is now */
void stage_disc_loop(void) {
    struct Object *o = gCurrentObject;
    stage_disc_shape_step(o);
    s16 pitch = 0, roll = 0;
    if (stage_tilting && gMarioState && gMarioState->area && gMarioState->area->camera) {
        /* The lean wanted: down the way the controller tips, as the stick would steer (camera-relative) */
        s16 ahead = (s16) (0x8000 + unity_stick_yaw(gMarioState->area->camera->yaw)), right = (s16) (ahead - 0x4000);
        float f = sinf(stage_tilt_in[0]), r = sinf(stage_tilt_in[1]);
        float nx = f * sins(ahead) + r * sins(right), nz = f * coss(ahead) + r * coss(right);
        float most = sins(STAGE_TILT_MOST), lean = sqrtf(nx * nx + nz * nz);
        if (lean > most) { nx *= most / lean; nz *= most / lean; }
        int pw, rw;
        stage_tilt_ways(&pw, &rw);
        roll = (s16) (rw * atan2s(sqrtf(1.f - nx * nx), nx));   /* (its up leant nx along x...) */
        pitch = (s16) (pw * atan2s(sqrtf(1.f - nx * nx - nz * nz), nz)); /* (...and nz along z) */
    }
    s16 oldPitch = (s16) o->oFaceAnglePitch, oldRoll = (s16) o->oFaceAngleRoll;
    o->oFaceAnglePitch = stage_tilt_toward(oldPitch, pitch);
    o->oFaceAngleRoll = stage_tilt_toward(oldRoll, roll);
    o->oFaceAngleYaw = 0;
    o->oAngleVelPitch = (s16) (o->oFaceAnglePitch - oldPitch);
    o->oAngleVelRoll = (s16) (o->oFaceAngleRoll - oldRoll);
    o->oAngleVelYaw = 0;
    /* What's on it rides along: the other Marios, the boxes (Mario: apply_mario_platform_displacement) */
    if (o->oAngleVelPitch || o->oAngleVelRoll) {
        for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
            struct UnityMario *u = &unity_marios[i];
            if (!u->obj || !(u->obj->activeFlags & ACTIVE_FLAG_ACTIVE) || !stage_on_disc(o, u->m.pos)) continue;
            stage_disc_carry(o, u->m.pos);
        }
        const BehaviorScript *box = segmented_to_virtual(bhvStageBox);
        for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
             b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next) {
            if (b->behavior != box || b->oHeldState != HELD_FREE) continue;
            Vec3f p = { b->oPosX, b->oPosY, b->oPosZ };
            if (!stage_on_disc(o, p)) continue;
            stage_disc_carry(o, p);
            b->oPosX = p[0]; b->oPosY = p[1]; b->oPosZ = p[2];
        }
    }
    /* The stage's pipe, stood on the disc where it was put */
    if (!stage_pipe || !(stage_pipe->activeFlags & ACTIVE_FLAG_ACTIVE) || stage_pipe->behavior != segmented_to_virtual(bhvWarpPipe)) {
        stage_pipe = NULL;
        const BehaviorScript *pipe = segmented_to_virtual(bhvWarpPipe);
        for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_SURFACE].next;
             b != (struct Object *) &gObjectLists[OBJ_LIST_SURFACE]; b = (struct Object *) b->header.next)
            if (b->behavior == pipe && stage_distance(b->oPosX, b->oPosZ, 0.f, STAGE_PIPE_Z) < 100.f) stage_pipe = b;
    }
    if (stage_pipe) {
        Vec3s angle = { (s16) o->oFaceAnglePitch, 0, (s16) o->oFaceAngleRoll };
        Vec3f at;
        stage_turned(angle, 0.f, stage_disc_mesh_height(stage_disc.now, 0.f, STAGE_PIPE_Z), STAGE_PIPE_Z, at);
        stage_pipe->oPosX = o->oPosX + at[0]; stage_pipe->oPosY = o->oPosY + at[1]; stage_pipe->oPosZ = o->oPosZ + at[2];
        stage_pipe->oFaceAnglePitch = o->oFaceAnglePitch; stage_pipe->oFaceAngleRoll = o->oFaceAngleRoll;
        stage_pipe->oFaceAngleYaw = 0;
        obj_build_transform_from_pos_and_angle(stage_pipe, O_POS_INDEX, O_FACE_ANGLE_INDEX);
    }
    obj_build_transform_from_pos_and_angle(o, O_POS_INDEX, O_FACE_ANGLE_INDEX);
    stage_disc_load_collision(o);
}

/* Each step, before the Marios' own (bhvStageMosaic, in the spawner list): your B with one in front rolls it,
 * rather than punching; D-pad up turns tilting on or off; the rest of the D-pad changes the disc's shape */
static int stage_celebration; /* (at 128 Marios: 0, not yet; then steps since) */
static void stage_celebration_step(void);
void stage_watch(void) {
    if (!stage_here() || !gMarioState || !gMarioState->controller) return;
    stage_celebration_step();
    unity_marios_let_go_taken(gMarioState); /* (yours, if another Mario took it the same step) */
    u16 pressed = gMarioState->controller->buttonPressed;
    if (pressed & B_BUTTON) stage_roll_start(gMarioState);
    if (pressed & U_JPAD) {
        stage_tilting = !stage_tilting;
        play_sound(stage_tilting ? SOUND_MENU_CAMERA_ZOOM_IN : SOUND_MENU_CAMERA_ZOOM_OUT, gDefaultSoundArgs);
    }
    /* D-pad right and left: the next shape, the one before; down: a pizza, and back */
    int shape = stage_disc.shape == STAGE_PIZZA ? stage_disc.last_shape : stage_disc.shape;
    if (pressed & R_JPAD) stage_disc_reshape((shape + 1) % STAGE_SHAPES);
    if (pressed & L_JPAD) stage_disc_reshape((shape + STAGE_SHAPES - 1) % STAGE_SHAPES);
    if (pressed & D_JPAD) stage_disc_reshape(stage_disc.shape == STAGE_PIZZA ? stage_disc.last_shape : STAGE_PIZZA);
}

/* An NPC Mario's mind: what its controller does this step */
enum { STAGE_NPC_IDLE, STAGE_NPC_WANDER, STAGE_NPC_FOLLOW, STAGE_NPC_GO_ROLL, STAGE_NPC_ROLLING, STAGE_NPC_GO_BOX,
       STAGE_NPC_CARRY, STAGE_NPC_SIT, STAGE_NPC_WAVE };
static u32 stage_npc_random(struct UnityMario *u) {
    u32 x = u->brain.seed ? u->brain.seed : 1;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return u->brain.seed = x;
}
static int stage_npc_between(struct UnityMario *u, int lo, int hi) { return lo + (int) (stage_npc_random(u) % (u32) (hi - lo + 1)); }

static int stage_npcs_paused; /* (for tests: they stand still) */
/* Is there room for more Marios? (Till there isn't, most of them go for boxes never picked up) */
static int stage_npc_room(void) { return unity_marios_npcs() < UNITY_NPC_MARIOS; }
static int stage_npcs_fetching = 1; /* (tests turn it off: they keep the Marios they made) */
void stage_npcs_fetch(int on) { stage_npcs_fetching = on; }
/* (tests) How many NPCs are going for a box or carrying one */
int stage_npcs_boxing(void) {
    int n = 0;
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++)
        if (unity_marios[i].obj && unity_marios[i].npc
            && (unity_marios[i].brain.mode == STAGE_NPC_GO_BOX || unity_marios[i].m.heldObj)) n++;
    return n;
}
/* A box another Mario could come out of: never picked up, lying free, on the disc, not one another NPC is after */
static int stage_npc_box_free(struct UnityMario *u, struct Object *b) {
    if (!b || !(b->activeFlags & ACTIVE_FLAG_ACTIVE) || b->behavior != segmented_to_virtual(bhvStageBox) || b->oAction
        || b->oHeldState != HELD_FREE || !stage_npc_room()
        || stage_distance(b->oPosX, b->oPosZ, 0.f, 0.f) > STAGE_NPC_SAFE) return 0;
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
        struct UnityMario *t = &unity_marios[i];
        if (t != u && t->obj && t->brain.mode == STAGE_NPC_GO_BOX && t->brain.box == b) return 0;
    }
    return 1;
}
/* The nearest such box, if any */
static struct Object *stage_npc_box_for(struct UnityMario *u) {
    if (!stage_npc_room() || !stage_npcs_fetching) return NULL;
    struct Object *best = NULL;
    float nearest = 1e9f;
    const BehaviorScript *box = segmented_to_virtual(bhvStageBox);
    for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
         b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next) {
        if (b->behavior != box || !stage_npc_box_free(u, b)) continue;
        float d = stage_distance(b->oPosX, b->oPosZ, u->m.pos[0], u->m.pos[2]);
        if (d < nearest) { nearest = d; best = b; }
    }
    return best;
}
static void stage_npc_think(struct UnityMario *u) {
    struct MarioState *m = &u->m;
    struct Controller *pad = &u->pad;
    if (stage_npcs_paused) { memset(pad, 0, sizeof(*pad)); u->brain.mode = STAGE_NPC_IDLE; u->brain.timer = 30; return; }
    /* Holding a box (whatever it meant to do as it got it): on with it a while, then thrown */
    if (m->heldObj && u->brain.mode != STAGE_NPC_CARRY) {
        u->brain.mode = STAGE_NPC_CARRY;
        u->brain.box = NULL;
        float a = stage_npc_between(u, 0, 0xFFFF), r = STAGE_NPC_ROAM * sqrtf(stage_npc_between(u, 0, 1000) / 1000.f);
        u->brain.x = r * sins((s16) a);
        u->brain.z = r * coss((s16) a);
        u->brain.timer = stage_npc_between(u, 40, 120);
    }
    /* What next, its time up for this (carrying, when it's thrown) */
    if (--u->brain.timer <= 0 && u->brain.mode != STAGE_NPC_CARRY) {
        struct UnityMario *other = NULL;
        struct Object *box = NULL;
        if (u->brain.mode == STAGE_NPC_IDLE && stage_npc_between(u, 1, 4) <= STAGE_NPC_BOX_IN_FOUR)
            box = stage_npc_box_for(u);
        if (box) {
            u->brain.mode = STAGE_NPC_GO_BOX;
            u->brain.box = box;
            u->brain.timer = 450;
        } else if (u->brain.mode == STAGE_NPC_IDLE && stage_npc_between(u, 1, STAGE_NPC_ROLL_ONE_IN) == 1) {
            float nearest = STAGE_NPC_ROLL_LOOK; /* (another to roll: the nearest) */
            for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
                struct UnityMario *t = &unity_marios[i];
                if (t == u || !stage_rollable(t)) continue;
                float d = stage_distance(t->m.pos[0], t->m.pos[2], m->pos[0], m->pos[2]);
                if (d < nearest) { nearest = d; other = t; }
            }
        }
        if (box) {
        } else if (other) {
            u->brain.mode = STAGE_NPC_GO_ROLL;
            u->brain.target = other;
            u->brain.timer = 300;
        } else if (u->brain.mode == STAGE_NPC_IDLE) {
            int pick = stage_npc_between(u, 0, 11);
            if (pick >= 10) { /* (now and then, a sit, or a wave at you) */
                u->brain.mode = STAGE_NPC_WAVE;
                u->brain.timer = stage_npc_between(u, 60, 150);
            } else if (pick >= 8) {
                u->brain.mode = STAGE_NPC_SIT;
                u->brain.timer = stage_npc_between(u, 150, 450);
            } else if (pick < 6) {
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
    u16 down = 0;
    /* Sitting, or waving at you: once it's stopped, where it stands; and when that's over, up again, or done */
    if (u->brain.mode == STAGE_NPC_SIT && m->action == ACT_IDLE) set_mario_action(m, ACT_STAGE_SIT, 0);
    if (u->brain.mode == STAGE_NPC_WAVE && m->action == ACT_IDLE) set_mario_action(m, ACT_STAGE_WAVE, 0);
    if (u->brain.mode != STAGE_NPC_SIT && m->action == ACT_STAGE_SIT) set_mario_action(m, ACT_WAKING_UP, 0);
    if (u->brain.mode != STAGE_NPC_WAVE && m->action == ACT_STAGE_WAVE) set_mario_action(m, ACT_IDLE, 0);
    /* Rolling one: B held, and on ahead, turning a little, till its time's up */
    if (u->brain.mode == STAGE_NPC_ROLLING) {
        if (m->action != ACT_STAGE_ROLL) {
            u->brain.mode = STAGE_NPC_IDLE;
            u->brain.timer = stage_npc_between(u, 20, 90);
        } else {
            down = B_BUTTON;
            u->brain.yaw = (s16) (m->faceAngle[1] + stage_npc_between(u, -0x200, 0x200));
            if (stage_distance(m->pos[0], m->pos[2], 0.f, 0.f) > STAGE_NPC_ROAM) /* (not towards the rim) */
                u->brain.yaw = atan2s(-m->pos[2], -m->pos[0]);
            speed = STAGE_NPC_WALK;
            if (u->brain.timer <= 1) down = 0; /* (let go: it tumbles on) */
        }
    }
    /* Going to roll one: up to it, then B, facing it */
    if (u->brain.mode == STAGE_NPC_GO_ROLL) {
        struct UnityMario *t = u->brain.target;
        if (!t || !stage_rollable(t)) {
            u->brain.mode = STAGE_NPC_IDLE;
            u->brain.timer = stage_npc_between(u, 20, 90);
        } else {
            float dx = t->m.pos[0] - m->pos[0], dz = t->m.pos[2] - m->pos[2];
            u->brain.yaw = atan2s(dz, dx);
            s16 off = (s16) (u->brain.yaw - m->faceAngle[1]);
            if (sqrtf(dx * dx + dz * dz) < STAGE_ROLL_REACH - 30.f && off < 0x1800 && off > -0x1800) {
                if (stage_roll_start(m)) {
                    u->brain.mode = STAGE_NPC_ROLLING;
                    u->brain.timer = stage_npc_between(u, 45, 150);
                    down = B_BUTTON;
                }
            } else speed = sqrtf(dx * dx + dz * dz) < 300.f ? 24.f : STAGE_NPC_WALK;
        }
    }
    /* Going for a box: up to it, facing it, then B (it picks it up, and another Mario hops out where it lay) */
    if (u->brain.mode == STAGE_NPC_GO_BOX) {
        struct Object *b = u->brain.box;
        if (!stage_npc_box_free(u, b) || u->brain.timer <= 1) {
            u->brain.mode = STAGE_NPC_IDLE; /* (another got it, or there's no room for more Marios: as before) */
            u->brain.box = NULL;
            u->brain.timer = stage_npc_between(u, 10, 40);
        } else if (m->action & (ACT_FLAG_ATTACKING | ACT_FLAG_AIR)) {
            /* (punching, picking up: let it) */
        } else {
            float dx = b->oPosX - m->pos[0], dz = b->oPosZ - m->pos[2], d = sqrtf(dx * dx + dz * dz);
            u->brain.yaw = atan2s(dz, dx);
            s16 off = (s16) (u->brain.yaw - m->faceAngle[1]);
            if (d < STAGE_NPC_GRAB_REACH && off < 0x1000 && off > -0x1000) {
                if (m->forwardVel < 4.f && !(pad->buttonDown & B_BUTTON)) down = B_BUTTON; /* (pressed, let up, pressed...) */
            } else if (d < STAGE_NPC_GRAB_REACH) {
                speed = 6.f; /* (turning to it) */
            } else speed = d < 300.f ? 16.f : STAGE_NPC_WALK;
        }
    }
    /* Carrying one: on towards somewhere, then thrown */
    if (u->brain.mode == STAGE_NPC_CARRY) {
        if (!m->heldObj) {
            u->brain.mode = STAGE_NPC_IDLE;
            u->brain.timer = stage_npc_between(u, 20, 60);
        } else if (u->brain.timer <= 1 || stage_distance(u->brain.x, u->brain.z, m->pos[0], m->pos[2]) < 150.f) {
            if (!(m->action & ACT_FLAG_THROWING) && !(pad->buttonDown & B_BUTTON)) down = B_BUTTON;
            u->brain.timer = 2; /* (till it's gone) */
        } else {
            u->brain.yaw = atan2s(u->brain.z - m->pos[2], u->brain.x - m->pos[0]);
            if (stage_distance(m->pos[0], m->pos[2], 0.f, 0.f) > STAGE_NPC_ROAM) u->brain.yaw = atan2s(-m->pos[2], -m->pos[0]);
            speed = 24.f;
        }
    }
    if (u->brain.mode < STAGE_NPC_GO_ROLL && sqrtf(m->pos[0] * m->pos[0] + m->pos[2] * m->pos[2]) > STAGE_NPC_SAFE) {
        /* (near the edge: back to the middle) */
        u->brain.mode = STAGE_NPC_WANDER;
        u->brain.x = u->brain.z = 0.f;
        u->brain.timer = 60;
    }
    if (u->brain.mode != STAGE_NPC_IDLE && u->brain.mode < STAGE_NPC_GO_ROLL) {
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
    if (u->brain.hold > 0) { u->brain.hold--; down |= A_BUTTON; }
    else if (speed > 0.f && u->brain.mode < STAGE_NPC_GO_ROLL && stage_npc_between(u, 1, STAGE_NPC_JUMP_ONE_IN) == 1) {
        u->brain.hold = 10;
        down |= A_BUTTON;
    }
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
        /* On a lean, it slides down it */
        struct Surface *floor;
        find_floor(o->oPosX, o->oPosY + 50.f, o->oPosZ, &floor);
        float vx = o->oForwardVel * sins(o->oMoveAngleYaw), vz = o->oForwardVel * coss(o->oMoveAngleYaw);
        if (floor) { vx += STAGE_SLOPE_PULL * floor->normal.x; vz += STAGE_SLOPE_PULL * floor->normal.z; }
        o->oForwardVel = sqrtf(vx * vx + vz * vz) * STAGE_BOX_GROUND_FRICTION;
        if (o->oForwardVel > 0.f) o->oMoveAngleYaw = atan2s(vz, vx);
        if (o->oForwardVel < 1.f) o->oForwardVel = 0.f;
    }
    /* Sliding along the floor, it goes by Marios rather than pushing them (an object pushing Mario minds no walls: the
     * boxes, touching, slid down a lean as one and pushed him into the stage's pipe). Thrown, in the air, it's solid,
     * to knock things over; settled, it's solid again, and can be picked up (the behaviour's loop makes it tangible
     * each step) */
    if (o->oForwardVel > STAGE_BOX_SLIDE_GHOST) {
        struct Surface *under;
        float floor_y = find_floor(o->oPosX, o->oPosY + 50.f, o->oPosZ, &under);
        if (under && o->oPosY - floor_y < 30.f) o->oIntangibleTimer = -1;
    }
}

void stage_box_loop(void) {
    struct Object *o = gCurrentObject;
    switch (o->oHeldState) {
        case HELD_FREE:
            stage_box_move(o);
            break;
        case HELD_HELD:
            if (!o->oAction) { /* (its first time: whichever Mario holds it, yours or another) */
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
/* (tests) How many times a box is drawn, from when it's watched */
static struct Object *stage_box_watched;
static int stage_box_draws;
void stage_box_watch(struct Object *o) { stage_box_watched = o; stage_box_draws = 0; }
int stage_box_drawn(void) { return stage_box_draws; }

/* Each face's shade, lit from above (of 255), as the box's colour is made darker for it: the sides' a little lighter,
 * for the relief on them (stage_gen.py's emboss) is a little darker than white where it's flat */
static const u8 stage_box_side_shades[4] = { 0xff, 0xd4, 0xe8, 0xe8 }; /* (+z, -z, +x, -x) */
#define STAGE_BOX_TOP_SHADE 0xff
#define STAGE_BOX_BOTTOM_SHADE 0x80
static void stage_box_shade(Gfx **g, u32 rgb, int shade) {
    gDPSetEnvColor((*g)++, ((rgb >> 16) & 0xFF) * shade / 255, ((rgb >> 8) & 0xFF) * shade / 255, (rgb & 0xFF) * shade / 255, 255);
}
Gfx *geo_stage_box(s32 callContext, struct GraphNode *node, UNUSED void *context) {
    if (callContext != GEO_CONTEXT_RENDER) return NULL;
    struct Object *o = gCurGraphNodeHeldObject ? gCurGraphNodeHeldObject->objNode : (struct Object *) gCurGraphNodeObject;
    struct GraphNodeGenerated *generated = (struct GraphNodeGenerated *) node;
    generated->fnNode.node.flags = (LAYER_OPAQUE << 8) | (generated->fnNode.node.flags & 0xFF);
    if (o && o == stage_box_watched) stage_box_draws++;
    Gfx *list = alloc_display_list(16 * sizeof(Gfx)), *g = list;
    if (!list) return NULL;
    u32 rgb = o ? (u32) o->oBehParams : 0xFFFFFF;
    gSPDisplayList(g++, stage_disc_dl_box_begin);
    for (int side = 0; side < 4; side++) {
        stage_box_shade(&g, rgb, stage_box_side_shades[side]);
        gSPDisplayList(g++, stage_disc_dl_box_sides[side]);
    }
    gSPDisplayList(g++, stage_disc_dl_box_plain);
    stage_box_shade(&g, rgb, STAGE_BOX_TOP_SHADE);
    gSPDisplayList(g++, stage_disc_dl_box_top);
    stage_box_shade(&g, rgb, STAGE_BOX_BOTTOM_SHADE);
    gSPDisplayList(g++, stage_disc_dl_box_bottom);
    gSPDisplayList(g++, stage_disc_dl_box_end);
    gSPEndDisplayList(g++);
    return list;
}

/* The picture's boxes on the disc (bhvStageMosaic's one step, where the stage's level script puts it) */
void stage_mosaic_lay(void) {
    struct Object *o = gCurrentObject;
    stage_celebration = 0; /* (a new visit: none yet) */
    for (int i = 0; i < STAGE_MOSAIC_BOXES; i++) {
        float x = (stage_mosaic[i].column - (STAGE_MOSAIC_WIDTH - 1) / 2.f) * STAGE_MOSAIC_SPACING;
        float z = STAGE_MOSAIC_Z + (stage_mosaic[i].row - (STAGE_MOSAIC_HEIGHT - 1) / 2.f) * STAGE_MOSAIC_SPACING;
        struct Object *box = spawn_object_abs_with_rot(o, 0, MODEL_STAGE_BOX, bhvStageBox, (s16) x, 0, (s16) z, 0, 0, 0);
        if (!box) break;
        box->oBehParams = (stage_mosaic[i].r << 16) | (stage_mosaic[i].g << 8) | stage_mosaic[i].b;
    }
}

/* At 128 Marios, a celebration: the star's fanfare, and every Mario waving at you; then the title theme, on till
 * Mario leaves (the stage has no music of its own before it, as Castle Grounds hasn't) */
#define STAGE_TITLE_AFTER 150 /* (steps: the fanfare over) */
static void stage_celebration_step(void) {
    if (!stage_celebration) {
        if (unity_marios_npcs() < UNITY_NPC_MARIOS) return;
        stage_celebration = 1;
        play_course_clear();
        play_sound(SOUND_MARIO_HERE_WE_GO, gMarioState->marioObj->header.gfx.cameraToObject);
        for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
            struct UnityMario *u = &unity_marios[i];
            if (!u->obj || !u->npc || u->m.heldObj) continue;
            u->brain.mode = STAGE_NPC_WAVE;
            u->brain.timer = STAGE_TITLE_AFTER + 30;
        }
        return;
    }
    if (++stage_celebration == STAGE_TITLE_AFTER) play_cutscene_music(SEQUENCE_ARGS(4, SEQ_MENU_TITLE_SCREEN));
}
/* (tests) Steps since the celebration began, 0 if it hasn't */
int stage_celebrated(void) { return stage_celebration; }

/* How many rolls there have been, and Marios knocked over by tumbling ones (for tests) */
int stage_rolls(void) { return stage_rolls_started; }
int stage_knocks(void) { return stage_tumbles_knocked; }
/* For tests: the n-th extra Mario (of sm64unity_marios' order); is it tumbling (1), or rolled along (2)? its state; the
 * NPCs standing still or not; one sent tumbling */
static struct UnityMario *stage_nth(int n) {
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++)
        if (unity_marios[i].obj && (unity_marios[i].obj->activeFlags & ACTIVE_FLAG_ACTIVE) && n-- == 0) return &unity_marios[i];
    return NULL;
}
int stage_tumbling(int n) { struct UnityMario *u = stage_nth(n); return u ? u->tumbling + (u->tumble.by != NULL) : -1; }
struct MarioState *stage_npc_state(int n) { struct UnityMario *u = stage_nth(n); return u ? &u->m : NULL; }
void stage_npcs_pause(int paused) { stage_npcs_paused = paused; }
/* (tests) The nth NPC sits (or waves, wave) a while, from now; and how many are sitting, and waving */
void stage_npc_pose(int n, int wave) {
    struct UnityMario *u = stage_nth(n);
    if (!u) return;
    u->brain.mode = wave ? STAGE_NPC_WAVE : STAGE_NPC_SIT;
    u->brain.timer = 200;
}
int stage_npcs_sitting(void) {
    int n = 0;
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) if (unity_marios[i].obj && unity_marios[i].m.action == ACT_STAGE_SIT) n++;
    return n;
}
int stage_npcs_waving(void) {
    int n = 0;
    for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) if (unity_marios[i].obj && unity_marios[i].m.action == ACT_STAGE_WAVE) n++;
    return n;
}
void stage_tumble_test(int n, float speed, s16 dir) { struct UnityMario *u = stage_nth(n); if (u) stage_tumble_start(u, NULL, speed, dir); }

/* How many NPC Marios there are (for tests) */
int stage_npcs(void) { return unity_marios_npcs(); }

/* How many Marios there are on the stage, Mario too, as the HUD shows it: the Mario head, an X and the number, in the
 * middle of the screen's bottom (render_hud: none of the HUD's own is there). The count last shown, for tests */
#define STAGE_HUD_Y 16
static int stage_hud_shown;
int stage_hud_count(void) { return stage_hud_shown; }
void stage_hud(void) {
    stage_hud_shown = 0;
    if (!stage_here() || !gMarioObject) return;
    int count = 1 + unity_marios_count(0) + unity_marios_count(1);
    int digits = count >= 100 ? 3 : count >= 10 ? 2 : 1;
    int x = SCREEN_WIDTH / 2 - (32 + 12 * digits) / 2; /* (the head and the X 16 each, a digit 12, as the lives) */
    print_text(x, STAGE_HUD_Y, ",");      /* 'Mario Head' glyph */
    print_text(x + 16, STAGE_HUD_Y, "*"); /* 'X' glyph */
    print_text_fmt_int(x + 32, STAGE_HUD_Y, "%d", count);
    if (stage_tilting) print_text(SCREEN_WIDTH / 2 - 32, STAGE_HUD_Y + 18, "TILT"); /* (on: over the count) */
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
