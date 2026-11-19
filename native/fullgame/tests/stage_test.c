/* Headless test of the disc stage (stage_disc.inc.c): the pipe by where Mario starts in Castle Grounds takes him to
 * area 2, he stands on its ground, and its own pipe brings him back by the first. On it, the boxes (picked up,
 * thrown) and the Marios that come out of them (unity_stage.inc.h). Run by run_room_objects_test.sh
 * (TEST=stage_test), against the game library built with no host. */
#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <time.h>
#include <ultra64.h>
#include "sm64.h"
#include "types.h"
#include "game/level_update.h"
#include "game/area.h"
#include "game/mario.h"
#include "game/object_list_processor.h"
#include "game/object_helpers.h"
#include "object_constants.h"
#include "object_fields.h"
#include "behavior_data.h"
#include "pc/cliopts.h"
#include "engine/math_util.h"
#include "engine/surface_collision.h"
#include "snapshot.h"
#include "audio/external.h"
#include "seq_ids.h"
#include <stdlib.h>

int sm64unity_init(const char *);
int sm64unity_tick(uint16_t, int8_t, int8_t);
int sm64unity_stage(void);
void sm64unity_cursor(int, float, float);
void sm64unity_mr_geometry(int);
int sm64unity_render_current(void);


int sm64unity_dropped_draws(void);
int stage_boxes(void);
int stage_mosaic_boxes(void);
int stage_npcs(void);
int stage_hud_count(void);
int stage_rolls(void);
int stage_knocks(void);
int stage_tumbling(int n);
struct MarioState *stage_npc_state(int n);
void stage_npcs_pause(int paused);
void stage_npcs_fetch(int on);
int stage_npcs_boxing(void);
void stage_npc_pose(int n, int wave);
int stage_npcs_sitting(void);
int stage_npcs_waving(void);
int stage_celebrated(void);
void unity_viewer(Vec3f out);
void sm64unity_billboards(int on, float x, float y, float z, float ux, float uy, float uz);
void stage_tumble_test(int n, float speed, s16 dir);
void sm64unity_stage_tilt(float forward, float right);
int sm64unity_stage_tilting(void);
int stage_disc_shape(void);
int stage_disc_changing(void);
int stage_disc_pizza(void);
extern const BehaviorScript bhvStageDisc[];
#define ACT_STAGE_ROLL 0x0000047E
#define ACT_STAGE_TUMBLE 0x0002047F
int stage_box_mario(struct Object *o);
void stage_box_watch(struct Object *o);
int stage_box_drawn(void);
int sm64unity_marios(float *out, int max);
extern const BehaviorScript bhvStageBox[];

static int failures;
#define CHECK(c, ...) do { if (c) printf("  ok   " __VA_ARGS__); else { printf("  FAIL " __VA_ARGS__); failures++; } printf("\n"); } while (0)

static void tick(uint16_t b) { sm64unity_tick(b, 0, 0); sm64unity_render_current(); }
static void tick_stick(uint16_t b, int8_t x, int8_t y) { sm64unity_tick(b, x, y); sm64unity_render_current(); }
/* A picture of the frame, where STAGE_SNAPSHOTS says (if it does) */
static void shot(const char *name) {
    const char *dir = getenv("STAGE_SNAPSHOTS");
    if (!dir) return;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.png", dir, name);
    snapshot(path, 960, 540);
    printf("  (picture: %s)\n", path);
}
/* And a near one, from beside m (side: its left, 1, or right, -1, or from ahead, 0), looking at it and at n */
static void shot_near(const char *name, struct MarioState *m, struct MarioState *n, int side) {
    const char *dir = getenv("STAGE_SNAPSHOTS");
    if (!dir) return;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.png", dir, name);
    float mid[3] = { (m->pos[0] + n->pos[0]) / 2, m->pos[1] + 70, (m->pos[2] + n->pos[2]) / 2 };
    s16 look = side ? (s16) (m->faceAngle[1] + side * 0x4000) : m->faceAngle[1];
    float eye[3] = { mid[0] + 420 * sins(look), mid[1] + 110, mid[2] + 420 * coss(look) };
    snapshot_from(path, 960, 540, eye, mid);
    printf("  (picture: %s)\n", path);
}
static float disc_height(float x, float z);
/* A picture of the whole disc, from above its rim (by the pipe's side), looking down at its middle */
static void overview(const char *name) {
    const char *dir = getenv("STAGE_SNAPSHOTS");
    if (!dir) return;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.png", dir, name);
    float eye[3] = { 2600, 2800, 5200 }, at[3] = { 0, 0, -300 };
    snapshot_from(path, 960, 540, eye, at);
    printf("  (picture: %s)\n", path);
}
/* The mean distance of the boxes from the disc's middle */
static float boxes_out(void) {
    float sum = 0; int n = 0;
    const BehaviorScript *behavior = segmented_to_virtual(bhvStageBox);
    for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
         b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next)
        if (b->behavior == behavior && b->oHeldState == HELD_FREE) { sum += hypotf(b->oPosX, b->oPosZ); n++; }
    return n ? sum / n : 0;
}
/* A change of shape, waited out: 1 if Mario and the first NPC stayed on their feet on it all the while */
static int ride_change(void) {
    int riding = 1;
    for (int i = 0; i < 100; i++) {
        tick(0);
        struct MarioState *n = stage_npc_state(0);
        if (fabsf(gMarioState->pos[1] - gMarioState->floorHeight) > 5.f || (gMarioState->action & ACT_FLAG_AIR)
            || fabsf(n->pos[1] - disc_height(n->pos[0], n->pos[2])) > 5.f || (n->action & ACT_FLAG_AIR)) riding = 0;
    }
    return riding;
}

/* The disc object, and how high its top is at (x, z) (from above, down onto it: not a box nor the pipe) */
static struct Object *the_disc(void) {
    const BehaviorScript *behavior = segmented_to_virtual(bhvStageDisc);
    for (struct Object *o = (struct Object *) gObjectLists[OBJ_LIST_SURFACE].next;
         o != (struct Object *) &gObjectLists[OBJ_LIST_SURFACE]; o = (struct Object *) o->header.next)
        if (o->behavior == behavior) return o;
    return NULL;
}
static float disc_height(float x, float z) {
    struct Surface *floor;
    float y = find_floor(x, 3000, z, &floor);
    return floor ? y : -99999;
}
/* Is the stage's pipe where the disc's lean puts it, leant as it is? */
static int stage_pipe_follows(struct Object *disc) {
    const BehaviorScript *pipe = segmented_to_virtual(bhvWarpPipe);
    for (struct Object *o = (struct Object *) gObjectLists[OBJ_LIST_SURFACE].next;
         o != (struct Object *) &gObjectLists[OBJ_LIST_SURFACE]; o = (struct Object *) o->header.next)
        if (o->behavior == pipe)
            return o->oFaceAnglePitch == disc->oFaceAnglePitch && o->oFaceAngleRoll == disc->oFaceAngleRoll
                && fabsf(o->oPosY) > 50.f;
    return 0;
}
/* Is the stage's pipe standing on the disc's top, where it was put? */
static int stage_pipe_follows_up(void) {
    const BehaviorScript *pipe = segmented_to_virtual(bhvWarpPipe);
    for (struct Object *o = (struct Object *) gObjectLists[OBJ_LIST_SURFACE].next;
         o != (struct Object *) &gObjectLists[OBJ_LIST_SURFACE]; o = (struct Object *) o->header.next)
        if (o->behavior == pipe) {
            if (hypotf(o->oPosX, o->oPosZ - 2400) < 10.f) return fabsf(o->oPosY - (-500.f * 2400 * 2400 / (3000.f * 3000.f))) < 2.f;
        }
    return 0;
}
/* An extra Mario put at (x, z), on its feet, facing yaw */
static void stand(struct MarioState *m, float x, float z, s16 yaw) {
    m->pos[0] = x; m->pos[1] = 0; m->pos[2] = z;
    m->vel[0] = m->vel[1] = m->vel[2] = 0; m->forwardVel = 0;
    m->faceAngle[1] = yaw;
    set_mario_action(m, ACT_IDLE, 0);
}
static void ticks(int n) { for (int i = 0; i < n; i++) tick(0); }

/* The box furthest along +x on the stage (the picture's right edge: nothing between it and the rim), of those never
 * picked up yet if `untaken` */
static struct Object *rightmost_box(int untaken) {
    struct Object *best = NULL;
    const BehaviorScript *behavior = segmented_to_virtual(bhvStageBox);
    for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
         b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next)
        if (b->behavior == behavior && (!untaken || !b->oAction) && (!best || b->oPosX > best->oPosX)) best = b;
    return best;
}

/* Mario put just +x of the box, facing it, and B pressed: 1 if he's holding it */
static int pick_up(struct Object *box) {
    gMarioState->pos[0] = box->oPosX + 100; gMarioState->pos[1] = 0; gMarioState->pos[2] = box->oPosZ;
    gMarioState->vel[0] = gMarioState->vel[1] = gMarioState->vel[2] = 0; gMarioState->forwardVel = 0;
    gMarioState->faceAngle[1] = -0x4000; /* (-x, towards it) */
    set_mario_action(gMarioState, ACT_IDLE, 0);
    ticks(5);
    for (int i = 0; i < 30 && gMarioState->heldObj != box; i++) tick(i < 2 ? B_BUTTON : 0);
    return gMarioState->heldObj == box;
}
static int throw_held(void) {
    ticks(20); /* (done picking it up) */
    for (int i = 0; i < 30 && gMarioState->heldObj; i++) tick(i < 2 ? B_BUTTON : 0);
    return !gMarioState->heldObj;
}

/* Mario dropped onto the top of the pipe at (x, y, z), then the game run until he's in area `area` (or not) */

static int through_pipe(float x, float y, float z, int area) {
    gMarioState->pos[0] = x; gMarioState->pos[1] = y + 400; gMarioState->pos[2] = z;
    gMarioState->vel[1] = 0;
    set_mario_action(gMarioState, ACT_FREEFALL, 0);
    for (int i = 0; i < 600; i++) {
        tick(0);
        if (gCurrLevelNum == LEVEL_CASTLE_GROUNDS && gCurrAreaIndex == area && gMarioObject
            && gMarioState->action != ACT_EMERGE_FROM_PIPE && (gMarioState->action & ACT_FLAG_STATIONARY)) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0); /* (all of it, if it crashes) */
    gCLIOpts.SkipIntro = 1;
    if (!sm64unity_init(argc > 1 ? argv[1] : ".")) { printf("init failed\n"); return 1; }
    sm64unity_mr_geometry(1);
    for (int i = 0; i < 2000 && sm64unity_stage() != 2; i++) tick(i % 20 < 2 ? START_BUTTON : 0);
    for (int i = 0; i < 2000 && (sm64unity_stage() != 3 || !gMarioObject || gCurrLevelNum != LEVEL_CASTLE_GROUNDS); i++) {
        sm64unity_cursor(1, 62, 77);
        tick(i % 20 < 2 ? A_BUTTON : 0);
    }
    sm64unity_cursor(0, 0, 0);
    if (!gMarioObject || gCurrLevelNum != LEVEL_CASTLE_GROUNDS) { printf("never got into Castle Grounds\n"); return 1; }
    ticks(200);
    printf("Castle Grounds, area %d, Mario at %.0f %.0f %.0f\n", gCurrAreaIndex, gMarioState->pos[0], gMarioState->pos[1],
           gMarioState->pos[2]);

    stage_npcs_fetch(0); /* (the Marios fetching boxes on their own: tested after the rest, with as many as there are) */
    CHECK(through_pipe(-2400, 260, 4400, 2), "the pipe by the start takes Mario to the disc stage (area %d)", gCurrAreaIndex);
    ticks(60);
    printf("  Mario at %.0f %.0f %.0f, floor at %.0f\n", gMarioState->pos[0], gMarioState->pos[1], gMarioState->pos[2],
           gMarioState->floorHeight);
    CHECK(gCurrAreaIndex == 2 && gMarioState->floor && fabsf(gMarioState->floorHeight) < 1.f
          && fabsf(gMarioState->pos[1]) < 1.f, "he stands on the stage's ground");
    CHECK(gMarioState->pos[2] > 2400 - 1500 && gMarioState->pos[2] < 2400 + 1500 && fabsf(gMarioState->pos[0]) < 1500,
          "he came out by the stage's pipe");

    /* Walking: the stick moves him over the ground */
    float before[3] = { gMarioState->pos[0], gMarioState->pos[1], gMarioState->pos[2] };
    for (int i = 0; i < 45; i++) { sm64unity_tick(0, 0, 80); sm64unity_render_current(); }
    ticks(30);
    float moved = hypotf(gMarioState->pos[0] - before[0], gMarioState->pos[2] - before[2]);
    CHECK(moved > 300 && gCurrAreaIndex == 2 && fabsf(gMarioState->pos[1]) < 1.f, "he runs on it (%.0f units)", moved);

    /* Off the edge: out of bounds, he stays on */
    gMarioState->pos[0] = 2900; gMarioState->pos[2] = 0;
    set_mario_action(gMarioState, ACT_IDLE, 0);
    gMarioState->faceAngle[1] = 0x4000; /* (+x) */
    for (int i = 0; i < 90; i++) { sm64unity_tick(0, 80, 0); sm64unity_render_current(); }
    ticks(30);
    CHECK(gCurrAreaIndex == 2 && gMarioState->pos[0] < 3050 && fabsf(gMarioState->pos[1]) < 1.f,
          "at the edge he stays on the stage (x %.0f)", gMarioState->pos[0]);

    /* The boxes: laid out as the picture, picked up, thrown, never broken */
    printf("Boxes:\n");
    CHECK(stage_boxes() == stage_mosaic_boxes(), "the picture's %d boxes are on the disc (%d)", stage_mosaic_boxes(), stage_boxes());
    float at[4 * 130];
    CHECK(stage_npcs() == 0 && sm64unity_marios(at, 130) == 0, "only Mario, at first");
    CHECK(stage_hud_count() == 1, "the count at the bottom of the screen says so (%d)", stage_hud_count());
    struct Object *box = rightmost_box(0);
    { /* (close up: the side of a box, embossed, and the next ones along) */
        const char *dir = getenv("STAGE_SNAPSHOTS");
        if (dir && box) {
            char path[1024];
            snprintf(path, sizeof(path), "%s/1-box-side.png", dir);
            float eye[3] = { box->oPosX + 260, 150, box->oPosZ + 120 }, look[3] = { box->oPosX, 55, box->oPosZ };
            snapshot_from(path, 960, 540, eye, look);
            printf("  (picture: %s)\n", path);
        }
    }
    CHECK(box && fabsf(box->oPosY) < 1.f && box->oBehParams != 0, "standing on it, coloured (0x%06x)",
          box ? (unsigned) box->oBehParams : 0);
    float lay[2] = { box->oPosX, box->oPosZ };
    CHECK(pick_up(box), "Mario picks it up with B");
    CHECK(stage_npcs() == 1 && sm64unity_marios(at, 130) == 1 && hypotf(at[0] - lay[0], at[2] - lay[1]) < 1.f,
          "and another Mario comes out of where it lay (%d)", stage_npcs());
    tick(0);
    CHECK(stage_hud_count() == 2, "two Marios counted (%d)", stage_hud_count());
    ticks(20);
    /* Thrown towards the rim (+x) */
    gMarioState->faceAngle[1] = 0x4000;
    float thrownFrom[3] = { gMarioState->pos[0], gMarioState->pos[1], gMarioState->pos[2] };
    CHECK(throw_held(), "and throws it with B");
    float highest = box->oPosY;
    for (int i = 0; i < 20; i++) { tick(0); if (box->oPosY > highest) highest = box->oPosY; }
    ticks(200);
    printf("  thrown from %.0f, landed at %.0f %.0f %.0f (highest %.0f)\n", thrownFrom[0], box->oPosX, box->oPosY, box->oPosZ,
           highest);
    CHECK((box->activeFlags & ACTIVE_FLAG_ACTIVE) && box->behavior == segmented_to_virtual(bhvStageBox),
          "it isn't broken nor gone");
    CHECK(box->oPosX - thrownFrom[0] > 300 && highest > 60, "it flew off, up and away (%.0f units)", box->oPosX - thrownFrom[0]);
    CHECK(fabsf(box->oPosY) < 1.f && hypotf(box->oPosX, box->oPosZ) < 3000 && box->oForwardVel == 0.f,
          "and came to rest on the disc");
    CHECK(stage_boxes() == stage_mosaic_boxes(), "all %d still there", stage_mosaic_boxes());
    /* Thrown hard into the rim: it bounces back off it */
    box->oPosX = 2700; box->oPosY = 50; box->oPosZ = 0; box->oMoveAngleYaw = 0x4000; box->oForwardVel = 60; box->oVelY = 0;
    ticks(200);
    CHECK((box->activeFlags & ACTIVE_FLAG_ACTIVE) && box->oPosX < 2900 && fabsf(box->oPosY) < 1.f,
          "thrown into the rim, it bounces back onto the disc (%.0f %.0f %.0f)", box->oPosX, box->oPosY, box->oPosZ);

    /* The Marios: one more for each box picked up, the first time only */
    printf("Marios:\n");
    CHECK(pick_up(box) && throw_held() && stage_npcs() == 1, "the same box again: no more (%d)", stage_npcs());
    for (int i = 0; i < 2; i++) {
        struct Object *next = rightmost_box(1);
        CHECK(next && pick_up(next) && throw_held(), "another box picked up");
    }
    CHECK(stage_npcs() == 3, "a Mario for each (%d)", stage_npcs());
    tick(0);
    CHECK(stage_hud_count() == 4, "four counted (%d)", stage_hud_count());
    /* Only the Mario holding a box has it in his hands, not every Mario */
    stage_npcs_pause(1);
    struct Object *held = rightmost_box(0);
    for (int i = 0; i < 3; i++) stand(stage_npc_state(i), held->oPosX + 100 + 120 * (i + 1), held->oPosZ, -0x4000);
    CHECK(pick_up(held), "Mario picks a box up, the others beside him");
    ticks(20);
    stage_box_watch(held);
    tick(0);
    CHECK(stage_box_drawn() == 1 && !stage_npc_state(0)->heldObj, "it's drawn once, in his hands only (%d)", stage_box_drawn());
    shot_near("7-holding", gMarioState, stage_npc_state(1), 1);
    CHECK(throw_held(), "and thrown");
    stage_box_watch(held);
    tick(0);
    CHECK(stage_box_drawn() == 1, "then drawn where it is, once (%d)", stage_box_drawn());
    stage_box_watch(NULL);
    stage_npcs_pause(0);
    /* On their own: about the disc, never off it */
    float from[4 * 3];
    sm64unity_marios(from, 3);
    gMarioState->pos[0] = -1500; gMarioState->pos[2] = 1500; /* (away from them, for them to come to) */
    int furthest = 0, jumped = 0;
    float nearest = 1e9f;
    for (int t = 0; t < 3000; t++) {
        tick(0);
        int n = sm64unity_marios(at, 3);
        for (int i = 0; i < n; i++) {
            float d = hypotf(at[4 * i] - from[4 * i], at[4 * i + 2] - from[4 * i + 2]);
            if (d > furthest) furthest = (int) d;
            if (at[4 * i + 1] > 100.f) jumped = 1;
            float m = hypotf(at[4 * i] - gMarioState->pos[0], at[4 * i + 2] - gMarioState->pos[2]);
            if (m < nearest) nearest = m;
        }
        if (stage_npcs() < 3) break;
    }
    CHECK(stage_npcs() == 3, "over %d steps none falls off the disc (%d left)", 3000, stage_npcs());
    CHECK(furthest > 1000 && jumped, "they wander (%d units at most) and jump", furthest);
    CHECK(nearest < 500.f, "and come over to Mario (%.0f units from him)", nearest);
    int n = sm64unity_marios(at, 3);
    int on = 1;
    for (int i = 0; i < n; i++) on &= hypotf(at[4 * i], at[4 * i + 2]) < 3000 && at[4 * i + 1] > -1.f;
    CHECK(on, "all on the disc");

    /* Rolling one: B with it just in front */
    printf("Rolling:\n");
    stage_npcs_pause(1);
    struct MarioState *a = stage_npc_state(0), *b = stage_npc_state(1), *c = stage_npc_state(2);
    stand(gMarioState, 0, 600, -0x4000); /* (-x: across the camera, behind him as he came out of the pipe) */
    stand(a, -120, 600, 0x4000);
    stand(b, 600, -800, 0);
    stand(c, -600, -800, 0);
    ticks(30);
    shot("1-before");
    tick(B_BUTTON);
    CHECK(gMarioState->action == ACT_STAGE_ROLL && stage_tumbling(0) == 2, "B: Mario rolls the one in front (%08x, %d)",
          gMarioState->action, stage_tumbling(0));
    float rolled_from[3] = { gMarioState->pos[0], 0, gMarioState->pos[2] };
    s16 spin0 = 0;
    int ahead = 1;
    float tilt = 0;
    for (int i = 0; i < 45; i++) {
        tick_stick(B_BUTTON, -100, 0); /* (stick left: -x, as the camera looks) */
        float d = hypotf(a->pos[0] - gMarioState->pos[0], a->pos[2] - gMarioState->pos[2]);
        s16 way = atan2s(a->pos[2] - gMarioState->pos[2], a->pos[0] - gMarioState->pos[0]);
        if (fabsf(d - 95.f) > 5.f || abs((s16) (way - gMarioState->faceAngle[1])) > 0x100) ahead = 0;
        if (i == 0) spin0 = a->marioObj->header.gfx.angle[2];
        if (i == 25) { shot("2-rolling"); shot_near("2-rolling-side", gMarioState, a, 1); }
        if (i == 30) shot_near("2-rolling-front", gMarioState, a, 0);
        if (i == 35) shot_near("2-rolling-other-side", gMarioState, a, -1);
        tilt = a->marioObj->header.gfx.angle[1];
    }
    float rolled = hypotf(gMarioState->pos[0] - rolled_from[0], gMarioState->pos[2] - rolled_from[2]);
    CHECK(gMarioState->action == ACT_STAGE_ROLL && rolled > 250, "B held, the stick: he rolls it along (%.0f units)", rolled);
    CHECK(ahead && stage_tumbling(0) == 2, "it just ahead of him all the way");
    CHECK(a->marioObj->header.gfx.angle[2] != spin0 && (s16) (tilt - gMarioState->faceAngle[1]) == 0x4000,
          "lying across the way, turning over (%d)", (int) (s16) (a->marioObj->header.gfx.angle[2] - spin0));
    CHECK(gMarioState->marioBodyState->torsoAngle[0] > 0, "he leans over it, hands out (%d)",
          gMarioState->marioBodyState->torsoAngle[0]);
    /* Let go: it tumbles on, into b on its way, and both get up */
    s16 way = gMarioState->faceAngle[1];
    stand(b, a->pos[0] + 400.f * sins(way), a->pos[2] + 400.f * coss(way), 0);
    float let_go[3] = { a->pos[0], 0, a->pos[2] };
    int knocks = stage_knocks();
    tick(0);
    CHECK(gMarioState->action != ACT_STAGE_ROLL && stage_tumbling(0) == 1, "B let up: he lets go, it tumbles on");
    int b_tumbled = 0;
    for (int i = 0; i < 400; i++) {
        tick(0);
        if (stage_tumbling(1) == 1) b_tumbled = 1;
        if (i == 6) { shot("3-tumbling"); shot_near("3-tumbling-near", a, a, 1); }
        if (i == 9) shot_near("3-tumbling-near-2", a, a, 1);
        if (i == 12) shot_near("3-tumbling-near-3", a, a, 1);
    }
    float went = hypotf(a->pos[0] - let_go[0], a->pos[2] - let_go[2]);
    CHECK(went > 150, "on ahead (%.0f units)", went);
    CHECK(b_tumbled && stage_knocks() > knocks, "and knocks over the one in its way");
    CHECK(stage_tumbling(0) == 0 && stage_tumbling(1) == 0 && !(a->action & ACT_FLAG_AIR) && a->action != ACT_STAGE_TUMBLE
          && b->action != ACT_STAGE_TUMBLE, "they get up again (%08x, %08x)", a->action, b->action);
    ticks(60);
    shot("4-up-again");
    CHECK(a->action == ACT_IDLE && b->action == ACT_IDLE && stage_npcs() == 3, "on their feet");
    /* Tumbling into the rim: back off it */
    stand(c, 2500, 0, 0x4000);
    stage_tumble_test(2, 40, 0x4000);
    float outmost = 0;
    for (int i = 0; i < 300; i++) { tick(0); if (c->pos[0] > outmost) outmost = c->pos[0]; }
    CHECK(stage_npcs() == 3 && c->pos[0] < outmost - 50 && outmost < 2950 && c->action != ACT_STAGE_TUMBLE,
          "tumbled at the rim, it rolls back off it (to %.0f, back to %.0f)", outmost, c->pos[0]);
    /* The NPCs roll each other */
    stage_npcs_pause(0);
    int rolls = stage_rolls();
    int most_tumbling = 0;
    for (int t = 0; t < 4000 && stage_rolls() - rolls < 2; t++) {
        tick(0);
        int n = 0;
        for (int i = 0; i < 3; i++) n += stage_tumbling(i) > 0;
        if (n > most_tumbling) most_tumbling = n;
    }
    CHECK(stage_rolls() - rolls >= 2 && most_tumbling > 0, "on their own, they roll each other (%d rolls)", stage_rolls() - rolls);
    ticks(600);
    CHECK(stage_npcs() == 3, "and none of them falls off (%d)", stage_npcs());
    /* Tilting: D-pad up, then the controller's lean */
    printf("Tilting:\n");
    stage_npcs_pause(1);
    struct Object *disc = the_disc();
    CHECK(disc && fabsf(disc_height(0, 0)) < 1.f && disc_height(1500, -1500) > -1.f && disc_height(1500, -1500) < 1.f,
          "the disc is an object, level, its top the ground");
    for (int i = 0; i < 3; i++) stand(stage_npc_state(i), -900 + 600 * i, -1200, 0);
    stand(gMarioState, 600, 600, 0);
    ticks(10);
    CHECK(!sm64unity_stage_tilting(), "tilting off at first");
    sm64unity_stage_tilt(0.5f, 0.f); /* (the controller tipped forward) */
    ticks(30);
    CHECK(disc->oFaceAnglePitch == 0 && disc->oFaceAngleRoll == 0, "off, the controller's lean does nothing");
    tick(U_JPAD);
    CHECK(sm64unity_stage_tilting(), "D-pad up: on");
    struct Object *slider = rightmost_box(0);
    float slid_from[2] = { slider->oPosX, slider->oPosZ };
    float npc_r = hypotf(stage_npc_state(0)->pos[0], stage_npc_state(0)->pos[2]);
    int riding = 1;
    for (int i = 0; i < 90; i++) {
        tick(0);
        struct MarioState *n = stage_npc_state(0);
        if (fabsf(gMarioState->pos[1] - gMarioState->floorHeight) > 5.f || (gMarioState->action & ACT_FLAG_AIR)
            || fabsf(n->pos[1] - disc_height(n->pos[0], n->pos[2])) > 5.f) riding = 0;
    }
    s16 downhill = (s16) (0x8000 + gMarioState->area->camera->yaw);
    float near_y = disc_height(-1500 * sins(downhill), -1500 * coss(downhill)), far_y = disc_height(1500 * sins(downhill), 1500 * coss(downhill));
    printf("  leant %d %d: %.0f behind, %.0f downhill (camera yaw %d)\n", (s16) disc->oFaceAnglePitch, (s16) disc->oFaceAngleRoll,
           near_y, far_y, gMarioState->area->camera->yaw);
    shot("5-tilted");
    { float eye[3] = { 3800 * sins(downhill + 0x4000), 700, 3800 * coss(downhill + 0x4000) }, at[3] = { 0, 0, 0 };
      const char *dir = getenv("STAGE_SNAPSHOTS");
      if (dir) { char path[1024]; snprintf(path, sizeof(path), "%s/5-tilted-side.png", dir); snapshot_from(path, 960, 540, eye, at); } }
    CHECK(far_y < -300 && near_y > 300, "the disc leans down the way the controller tips, as the camera looks");
    CHECK(riding, "Mario and the others ride it, on their feet");
    CHECK(fabsf(hypotf(stage_npc_state(0)->pos[0], stage_npc_state(0)->pos[2]) - npc_r) < 120,
          "turning with it about its middle");
    float slid = (slider->oPosX - slid_from[0]) * sins(downhill) + (slider->oPosZ - slid_from[1]) * coss(downhill);
    CHECK(slid > 100, "a box slides down it (%.0f units)", slid);
    CHECK(stage_pipe_follows(disc), "the stage's pipe leans with it");
    sm64unity_stage_tilt(0.f, 0.5f); /* (tipped to the right instead) */
    ticks(90);
    s16 right = (s16) (downhill - 0x4000);
    CHECK(disc_height(1500 * sins(right), 1500 * coss(right)) < -300, "tipped right, it leans right");
    tick(U_JPAD);
    ticks(90);
    CHECK(!sm64unity_stage_tilting() && disc->oFaceAnglePitch == 0 && disc->oFaceAngleRoll == 0
          && fabsf(disc_height(1500, 1500)) < 1.f, "D-pad up again: off, and it eases back level");
    CHECK(fabsf(gMarioState->pos[1] - gMarioState->floorHeight) < 5.f && stage_npcs() == 3, "everyone still on it");
    sm64unity_stage_tilt(0.f, 0.f);

    /* Shapes: the rest of the D-pad */
    printf("Shapes:\n");
    for (int i = 0; i < 3; i++) stand(stage_npc_state(i), -900 + 600 * i, -1200, 0);
    stand(gMarioState, 600, 600, 0);
    ticks(10);
    CHECK(stage_disc_shape() == 0 && !stage_disc_pizza() && !stage_disc_changing(), "flat at first, with its own picture");
    overview("6-flat");
    float spread = boxes_out();
    tick(R_JPAD);
    CHECK(stage_disc_changing() && stage_disc_shape() == 1, "D-pad right: changing to the next shape");
    float halfway = 0;
    for (int i = 0; i < 44; i++) tick(0);
    halfway = disc_height(0, 0);
    int rode = ride_change();
    CHECK(!stage_disc_changing() && fabsf(disc_height(0, 0) - 900) < 5 && halfway > 200 && halfway < 700,
          "a hill, eased into (%.0f halfway, %.0f high)", halfway, disc_height(0, 0));
    CHECK(rode && gMarioState->pos[1] > 600, "Mario and the others rise with it, on their feet (Mario %.0f up)", gMarioState->pos[1]);
    CHECK(boxes_out() > spread + 100, "and the boxes slide down it, out (%.0f to %.0f)", spread, boxes_out());
    shot("6-hill-near");
    overview("6-hill");
    tick(R_JPAD);
    rode = ride_change();
    CHECK(fabsf(disc_height(0, 0)) < 5 && disc_height(2700, 0) > 500 && rode, "then a valley (%.0f at its rim)", disc_height(2700, 0));
    overview("6-valley");
    tick(R_JPAD);
    rode = ride_change();
    CHECK(fabsf(disc_height(0, 600) - 217) < 3 && fabsf(disc_height(0, 1500)) < 3 && rode, "then dunes (%.0f on the first)",
          disc_height(0, 600));
    overview("6-dunes");
    tick(R_JPAD);
    rode = ride_change();
    CHECK(disc_height(2000, 0) > 150 && disc_height(0, 2000) < -150 && rode, "then a pass (%.0f, %.0f)", disc_height(2000, 0),
          disc_height(0, 2000));
    overview("6-pass");
    CHECK(stage_pipe_follows_up(), "the stage's pipe stands on it where it's put");
    tick(L_JPAD);
    ride_change();
    CHECK(stage_disc_shape() == 3 && fabsf(disc_height(0, 600) - 217) < 3, "D-pad left: back to the dunes");
    tick(D_JPAD);
    for (int i = 0; i < 40; i++) tick(0);
    CHECK(!stage_disc_pizza(), "D-pad down: not a pizza yet, early on");
    for (int i = 0; i < 10; i++) tick(0);
    CHECK(stage_disc_pizza(), "its picture a pizza's halfway");
    rode = ride_change();
    CHECK(stage_disc_shape() == 5 && fabsf(disc_height(0, 0)) < 5 && disc_height(2990, 0) > 60 && rode,
          "a pizza, its crust a lip at the rim (%.0f)", disc_height(2990, 0));
    overview("6-pizza");
    shot("6-pizza-near");
    tick(D_JPAD);
    ride_change();
    CHECK(stage_disc_shape() == 3 && !stage_disc_pizza() && fabsf(disc_height(0, 600) - 217) < 3,
          "D-pad down again: back to the dunes");
    tick(R_JPAD);
    for (int i = 0; i < 30; i++) tick(0);
    tick(R_JPAD); /* (changing still: on to the next from where it is) */
    rode = ride_change();
    CHECK(stage_disc_shape() == 0 && fabsf(disc_height(750, 0)) < 1 && fabsf(disc_height(1500, -1500)) < 1 && rode,
          "and right, partway, then right again: flat");
    CHECK(fabsf(gMarioState->pos[1] - gMarioState->floorHeight) < 5.f && stage_npcs() == 3, "everyone still on it");
    stage_npcs_pause(0);

    /* Now and then, one sits a while, or waves at you */
    printf("Sitting and waving:\n");
    {
        u16 music = get_current_background_music();
        CHECK(music == 0xFFFF || (music & 0xFF) == 0, "(no music on the stage: %04x)", music);
        stand(gMarioState, 0, 1500, 0);
        struct MarioState *sitter = stage_npc_state(0), *waver = stage_npc_state(1);
        stand(sitter, -250, 2000, 0x4000);
        stand(waver, 250, 2000, 0x4000);
        stand(stage_npc_state(2), 900, -900, 0);
        stage_npc_pose(0, 0);
        stage_npc_pose(1, 1);
        ticks(45);
        Vec3f you;
        unity_viewer(you);
        s16 to_you = atan2s(you[2] - waver->pos[2], you[0] - waver->pos[0]), off = (s16) (waver->faceAngle[1] - to_you);
        CHECK(sitter->action == 0x0C00021E && fabsf(sitter->pos[1] - sitter->floorHeight) < 2.f, "one sits down");
        CHECK(waver->action == 0x0C00021F && abs(off) < 0x200, "and one waves, turned to the camera (%d off)", off);
        CHECK(fabsf(sitter->pos[0] + 250) < 5 && fabsf(waver->pos[0] - 250) < 5 && fabsf(waver->pos[2] - 2000) < 5, "both where they stood");
        shot("9-sitting-waving");
        shot_near("9-waving-near", waver, waver, 0);
        shot_near("9-sitting-near", sitter, sitter, 1);
        /* In MR, at your head: straight ahead of the game camera, then off to its right */
        Vec3f eye, ahead, right;
        vec3f_copy(eye, you);
        sm64unity_billboards(1, 0, 0, -1000, 0, 1, 0);
        unity_viewer(ahead);
        sm64unity_billboards(1, 1000, 0, 0, 0, 1, 0);
        unity_viewer(right);
        float fx = gLakituState.focus[0] - eye[0], fy = gLakituState.focus[1] - eye[1], fz = gLakituState.focus[2] - eye[2];
        float fn = sqrtf(fx * fx + fy * fy + fz * fz);
        fx /= fn; fy /= fn; fz /= fn;
        float hn = hypotf(fx, fz);
        CHECK(fabsf(ahead[0] - (eye[0] + 1000 * fx)) < 2 && fabsf(ahead[1] - (eye[1] + 1000 * fy)) < 2
              && fabsf(ahead[2] - (eye[2] + 1000 * fz)) < 2, "in MR, your head is found in the level: ahead");
        CHECK(fabsf(right[0] - (eye[0] - 1000 * fz / hn)) < 2 && fabsf(right[2] - (eye[2] + 1000 * fx / hn)) < 2
              && fabsf(right[1] - eye[1]) < 2, "and to the right");
        ticks(40);
        to_you = atan2s(right[2] - waver->pos[2], right[0] - waver->pos[0]);
        off = (s16) (waver->faceAngle[1] - to_you);
        CHECK(waver->action == 0x0C00021F && abs(off) < 0x200, "and he waves at it (%d off)", off);
        sm64unity_billboards(0, 0, 0, 0, 0, 1, 0);
        int got_up = 0, stopped = 0;
        for (int i = 0; i < 260; i++) {
            tick(0);
            if (sitter->action == ACT_WAKING_UP) got_up = 1;
            if (waver->action != 0x0C00021F) stopped = 1;
        }
        CHECK(got_up && stopped, "then the one gets up, and the other stops");
        int sat = 0, waved = 0;
        for (int i = 0; i < 2400 && !(sat && waved); i++) {
            tick(0);
            if (stage_npcs_sitting()) sat = 1;
            if (stage_npcs_waving()) waved = 1;
        }
        CHECK(sat && waved, "and on their own, now and then, they sit, and wave");
    }

    /* On their own, most go for boxes no one has picked up yet, till there are as many Marios as there can be */
    printf("Fetching boxes:\n");
    stage_npcs_fetch(1);
    int npcs_before = stage_npcs(), held_by_npc = 0;
    float boxing = 0, all = 0;
    for (int i = 0; i < 600; i++) {
        tick(0);
        if (i >= 100) { boxing += stage_npcs_boxing(); all += stage_npcs(); }
        for (int k = 0; k < stage_npcs(); k++) if (stage_npc_state(k) && stage_npc_state(k)->heldObj) held_by_npc = 1;
        if (i == 300) overview("8-fetching");
    }
    CHECK(boxing > all / 2 && held_by_npc, "most of them go for boxes, and lift them (%.0f%% of the time)", 100 * boxing / all);
    CHECK(stage_npcs() > npcs_before + 3, "and more Marios hop out of them (%d, from %d)", stage_npcs(), npcs_before);
    int grown = stage_npcs();
    for (int i = 0; i < 9000 && stage_npcs() < 128 && stage_npcs() < stage_mosaic_boxes(); i++) tick(0);
    printf("  %d Marios\n", stage_npcs());
    if (stage_npcs() == 128) {
        tick(0); /* (the 128th's step done: the stage notices it on the next) */
        CHECK(stage_celebrated() > 0 && stage_celebrated() < 60, "at 128, a celebration (%d steps ago)", stage_celebrated());
        while (stage_celebrated() && stage_celebrated() < 45) tick(0);
        CHECK(stage_npcs_waving() > 64, "everyone waving at you (%d)", stage_npcs_waving());
        shot("8-celebration");
        overview("8-many");
        CHECK(get_current_background_music() != (u16) SEQUENCE_ARGS(4, SEQ_MENU_TITLE_SCREEN), "the fanfare first");
        ticks(120);
        CHECK(get_current_background_music() == (u16) SEQUENCE_ARGS(4, SEQ_MENU_TITLE_SCREEN), "then the title theme (%04x)",
              get_current_background_music());
    } else printf("  (only %d boxes in the picture: never 128 Marios, so no celebration to see)\n", stage_mosaic_boxes());
    ticks(60);
    CHECK(stage_npcs() > grown, "on till there are many more (%d)", stage_npcs());
    int untaken = 0;
    for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
         b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next)
        if (b->behavior == segmented_to_virtual(bhvStageBox) && !b->oAction) untaken++;
    ticks(300);
    if (stage_mosaic_boxes() > 128)
        CHECK(stage_npcs() == 128 && untaken > 0 && stage_npcs_boxing() == 0,
              "at 128, no more go for boxes, though %d lie untaken (%d going for one or holding one)", untaken, stage_npcs_boxing());

    /* Every box: as many Marios as there can be */
    const BehaviorScript *boxes = segmented_to_virtual(bhvStageBox);
    for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
         b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next)
        if (b->behavior == boxes && !b->oAction) { b->oAction = 1; stage_box_mario(b); }
    int most = stage_npcs();
    CHECK(most == (stage_mosaic_boxes() < 128 ? stage_mosaic_boxes() : 128), "%d Marios at most (%d boxes)", most,
          stage_mosaic_boxes());
    clock_t start = clock();
    ticks(300);
    double ms = 1000.0 * (clock() - start) / CLOCKS_PER_SEC / 300;
    printf("  %d Marios: %.2f ms a step (with drawing)\n", stage_npcs(), ms);
    { int nb, nf; sm64unity_batches(&nb); sm64unity_vertices(&nf);
      CHECK(sm64unity_dropped_draws() == 0, "all of them drawn (%d batches, %d floats; %d draws with no room)", nb, nf,
            sm64unity_dropped_draws()); }
    CHECK(stage_npcs() >= most - 2, "they get along (%d of %d left)", stage_npcs(), most);
    CHECK(stage_hud_count() == 1 + stage_npcs(), "all counted (%d)", stage_hud_count());

    tick(D_JPAD);
    ticks(100);
    CHECK(stage_disc_shape() == 5, "a pizza again, to leave it so");
    CHECK(through_pipe(0, 0, 2400, 1), "the stage's pipe takes him back to Castle Grounds (area %d)", gCurrAreaIndex);
    ticks(60);
    printf("  Mario at %.0f %.0f %.0f\n", gMarioState->pos[0], gMarioState->pos[1], gMarioState->pos[2]);
    CHECK(gCurrAreaIndex == 1 && hypotf(gMarioState->pos[0] + 2400, gMarioState->pos[2] - 4400) < 1500
          && fabsf(gMarioState->pos[1] - 260) < 1.f, "by the first pipe, on the grass");
    CHECK(stage_npcs() == 0, "the other Marios stay behind (%d)", stage_npcs());
    CHECK(stage_hud_count() == 0, "no count off the stage");

    CHECK(through_pipe(-2400, 260, 4400, 2), "and through it again");
    CHECK(stage_boxes() == stage_mosaic_boxes(), "the picture laid out again (%d boxes)", stage_boxes());
    {
        float nearest = 1e9f;
        const BehaviorScript *bx = segmented_to_virtual(bhvStageBox);
        for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
             b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next)
            for (struct Object *c = (struct Object *) b->header.next;
                 c != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; c = (struct Object *) c->header.next)
                if (b->behavior == bx && c->behavior == bx) {
                    float d = hypotf(b->oPosX - c->oPosX, b->oPosZ - c->oPosZ);
                    if (d < nearest) nearest = d;
                }
        CHECK(fabsf(nearest - 110) < 1, "touching, side by side, 110 across (%.1f apart)", nearest);
    }
    CHECK(stage_npcs() == 0, "and only Mario again");
    CHECK(stage_disc_shape() == 0 && !stage_disc_pizza() && fabsf(disc_height(2850, 0)) < 1, "and the disc flat, its own again");

    printf(failures ? "FAILED (%d failures)\n" : "PASSED (%d failures)\n", failures);
    return failures != 0;
}
