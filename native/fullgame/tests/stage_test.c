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
#include "snapshot.h"
#include <stdlib.h>

int sm64unity_init(const char *);
int sm64unity_tick(uint16_t, int8_t, int8_t);
int sm64unity_stage(void);
void sm64unity_cursor(int, float, float);
void sm64unity_mr_geometry(int);
int sm64unity_render_current(void);
int stage_boxes(void);
int stage_mosaic_boxes(void);
int stage_npcs(void);
int stage_hud_count(void);
int stage_rolls(void);
int stage_knocks(void);
int stage_tumbling(int n);
struct MarioState *stage_npc_state(int n);
void stage_npcs_pause(int paused);
void stage_tumble_test(int n, float speed, s16 dir);
#define ACT_STAGE_ROLL 0x0000047E
#define ACT_STAGE_TUMBLE 0x0002047F
int stage_box_mario(struct Object *o);
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
    CHECK(stage_npcs() >= most - 2, "they get along (%d of %d left)", stage_npcs(), most);
    CHECK(stage_hud_count() == 1 + stage_npcs(), "all counted (%d)", stage_hud_count());

    CHECK(through_pipe(0, 0, 2400, 1), "the stage's pipe takes him back to Castle Grounds (area %d)", gCurrAreaIndex);
    ticks(60);
    printf("  Mario at %.0f %.0f %.0f\n", gMarioState->pos[0], gMarioState->pos[1], gMarioState->pos[2]);
    CHECK(gCurrAreaIndex == 1 && hypotf(gMarioState->pos[0] + 2400, gMarioState->pos[2] - 4400) < 1500
          && fabsf(gMarioState->pos[1] - 260) < 1.f, "by the first pipe, on the grass");
    CHECK(stage_npcs() == 0, "the other Marios stay behind (%d)", stage_npcs());
    CHECK(stage_hud_count() == 0, "no count off the stage");

    CHECK(through_pipe(-2400, 260, 4400, 2), "and through it again");
    CHECK(stage_boxes() == stage_mosaic_boxes(), "the picture laid out again (%d boxes)", stage_boxes());
    CHECK(stage_npcs() == 0, "and only Mario again");

    printf(failures ? "FAILED (%d failures)\n" : "PASSED (%d failures)\n", failures);
    return failures != 0;
}
