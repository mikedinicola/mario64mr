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
 *   stage's pipe here), and boxes and tumbling Marios slide and roll downhill. */

#include "levels/castle_grounds/header.h"
#include "game/memory.h"
#include "game/rendering_graph_node.h"
#include "audio/external.h"
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
/* Tilting: how far it leans at most, how quickly it turns, how hard things slide down it */
#define STAGE_TILT_MOST 0x1000
#define STAGE_TILT_RATE 0x80
#define STAGE_SLOPE_PULL 8.f

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
    struct Surface *floor;
    float y = find_floor(x, 4000.f, z, &floor); /* (the disc there, however it leans) */
    if (!floor) return 0;
    struct UnityMario *u = unity_marios_make(x, y, z, yaw, 1);
    if (!u) return 0;
    u->m.action = ACT_JUMP; /* (it hops out) */
    u->m.vel[1] = 42.f;
    u->brain.mode = 0;
    u->brain.timer = 30;
    play_sound(SOUND_GENERAL_COLLECT_1UP, gDefaultSoundArgs);
    return 1;
}

/* Is Mario on the stage? */
static int stage_here(void) { return gCurrLevelNum == LEVEL_CASTLE_GROUNDS && gCurrAreaIndex == 2; }

/* Rolling: who's rolling it, and who it is */
#define ACT_STAGE_ROLL 0x0000047E /* (0x07E | ACT_FLAG_MOVING) rolling another Mario along: stage_act_roll */
#define ACT_STAGE_TUMBLE 0x0002047F /* (0x07F | ACT_FLAG_MOVING | ACT_FLAG_INVULNERABLE) rolled, tumbling: the extra
                                       Marios' only (stage_tumble_step, in place of the Mario code) */
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
    return t->obj && !t->tumbling && !t->lost && !(t->m.action & ACT_FLAG_AIR) && t->m.action != ACT_STAGE_ROLL
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
/* Standing on the disc (on its floor, within a few units of it)? */
static int stage_on_disc(struct Object *disc, Vec3f p) {
    struct Surface *floor;
    float y = find_floor(p[0], p[1] + 50.f, p[2], &floor);
    return floor && floor->object == disc && fabsf(p[1] - y) < 8.f;
}

/* The disc's step (bhvStageDisc, in the surface list: before Mario's platform displacement and everyone's own step):
 * it leans towards the controller's lean, or back level; what's on it rides along; its collision where it is now */
void stage_disc_loop(void) {
    struct Object *o = gCurrentObject;
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
    o->oFaceAnglePitch = stage_turn_toward(oldPitch, pitch, STAGE_TILT_RATE);
    o->oFaceAngleRoll = stage_turn_toward(oldRoll, roll, STAGE_TILT_RATE);
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
        stage_turned(angle, 0.f, 0.f, STAGE_PIPE_Z, at);
        stage_pipe->oPosX = o->oPosX + at[0]; stage_pipe->oPosY = o->oPosY + at[1]; stage_pipe->oPosZ = o->oPosZ + at[2];
        stage_pipe->oFaceAnglePitch = o->oFaceAnglePitch; stage_pipe->oFaceAngleRoll = o->oFaceAngleRoll;
        stage_pipe->oFaceAngleYaw = 0;
        obj_build_transform_from_pos_and_angle(stage_pipe, O_POS_INDEX, O_FACE_ANGLE_INDEX);
    }
    obj_build_transform_from_pos_and_angle(o, O_POS_INDEX, O_FACE_ANGLE_INDEX);
    load_object_collision_model();
}

/* Each step, before the Marios' own (bhvStageMosaic, in the spawner list): your B with one in front rolls it,
 * rather than punching; D-pad up turns tilting on or off */
void stage_watch(void) {
    if (!stage_here() || !gMarioState || !gMarioState->controller) return;
    u16 pressed = gMarioState->controller->buttonPressed;
    if (pressed & B_BUTTON) stage_roll_start(gMarioState);
    if (pressed & U_JPAD) {
        stage_tilting = !stage_tilting;
        play_sound(stage_tilting ? SOUND_MENU_CAMERA_ZOOM_IN : SOUND_MENU_CAMERA_ZOOM_OUT, gDefaultSoundArgs);
    }
}

/* An NPC Mario's mind: what its controller does this step */
enum { STAGE_NPC_IDLE, STAGE_NPC_WANDER, STAGE_NPC_FOLLOW, STAGE_NPC_GO_ROLL, STAGE_NPC_ROLLING };
static u32 stage_npc_random(struct UnityMario *u) {
    u32 x = u->brain.seed ? u->brain.seed : 1;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return u->brain.seed = x;
}
static int stage_npc_between(struct UnityMario *u, int lo, int hi) { return lo + (int) (stage_npc_random(u) % (u32) (hi - lo + 1)); }

static int stage_npcs_paused; /* (for tests: they stand still) */
static void stage_npc_think(struct UnityMario *u) {
    struct MarioState *m = &u->m;
    struct Controller *pad = &u->pad;
    if (stage_npcs_paused) { memset(pad, 0, sizeof(*pad)); u->brain.mode = STAGE_NPC_IDLE; u->brain.timer = 30; return; }
    /* What next, its time up for this */
    if (--u->brain.timer <= 0) {
        struct UnityMario *other = NULL;
        if (u->brain.mode == STAGE_NPC_IDLE && stage_npc_between(u, 1, STAGE_NPC_ROLL_ONE_IN) == 1) {
            float nearest = STAGE_NPC_ROLL_LOOK; /* (another to roll: the nearest) */
            for (int i = 0; i < UNITY_EXTRA_MARIOS; i++) {
                struct UnityMario *t = &unity_marios[i];
                if (t == u || !stage_rollable(t)) continue;
                float d = stage_distance(t->m.pos[0], t->m.pos[2], m->pos[0], m->pos[2]);
                if (d < nearest) { nearest = d; other = t; }
            }
        }
        if (other) {
            u->brain.mode = STAGE_NPC_GO_ROLL;
            u->brain.target = other;
            u->brain.timer = 300;
        } else if (u->brain.mode == STAGE_NPC_IDLE) {
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
    u16 down = 0;
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
