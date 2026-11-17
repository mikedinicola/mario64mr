/* Headless test of the disc stage (stage_disc.inc.c): the pipe by where Mario starts in Castle Grounds takes him to
 * area 2, he stands on its ground, and its own pipe brings him back by the first. Run by run_room_objects_test.sh
 * (TEST=stage_test), against the game library built with no host. */
#include <stdio.h>
#include <stdint.h>
#include <math.h>
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

int sm64unity_init(const char *);
int sm64unity_tick(uint16_t, int8_t, int8_t);
int sm64unity_stage(void);
void sm64unity_cursor(int, float, float);
void sm64unity_mr_geometry(int);
int sm64unity_render_current(void);
int stage_boxes(void);
int stage_mosaic_boxes(void);
extern const BehaviorScript bhvStageBox[];

static int failures;
#define CHECK(c, ...) do { if (c) printf("  ok   " __VA_ARGS__); else { printf("  FAIL " __VA_ARGS__); failures++; } printf("\n"); } while (0)

static void tick(uint16_t b) { sm64unity_tick(b, 0, 0); sm64unity_render_current(); }
static void ticks(int n) { for (int i = 0; i < n; i++) tick(0); }

/* Mario dropped onto the top of the pipe at (x, y, z), then the game run until he's in area `area` (or not) */
/* The box furthest along +x on the stage (the picture's right edge: nothing between it and the rim) */
static struct Object *rightmost_box(void) {
    struct Object *best = NULL;
    const BehaviorScript *behavior = segmented_to_virtual(bhvStageBox);
    for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
         b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE]; b = (struct Object *) b->header.next)
        if (b->behavior == behavior && (!best || b->oPosX > best->oPosX)) best = b;
    return best;
}

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
    struct Object *box = rightmost_box();
    CHECK(box && fabsf(box->oPosY) < 1.f && box->oBehParams != 0, "standing on it, coloured (0x%06x)",
          box ? (unsigned) box->oBehParams : 0);
    gMarioState->pos[0] = box->oPosX + 100; gMarioState->pos[1] = 0; gMarioState->pos[2] = box->oPosZ;
    gMarioState->vel[0] = gMarioState->vel[1] = gMarioState->vel[2] = 0; gMarioState->forwardVel = 0;
    gMarioState->faceAngle[1] = -0x4000; /* (-x, towards it) */
    set_mario_action(gMarioState, ACT_IDLE, 0);
    ticks(5);
    for (int i = 0; i < 30 && gMarioState->heldObj != box; i++) tick(i < 2 ? B_BUTTON : 0);
    CHECK(gMarioState->heldObj == box, "Mario picks it up with B");
    ticks(20);
    /* Thrown towards the rim (+x) */
    gMarioState->faceAngle[1] = 0x4000;
    float thrownFrom[3] = { gMarioState->pos[0], gMarioState->pos[1], gMarioState->pos[2] };
    for (int i = 0; i < 30 && gMarioState->heldObj; i++) tick(i < 2 ? B_BUTTON : 0);
    CHECK(!gMarioState->heldObj, "and throws it with B");
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

    CHECK(through_pipe(0, 0, 2400, 1), "the stage's pipe takes him back to Castle Grounds (area %d)", gCurrAreaIndex);
    ticks(60);
    printf("  Mario at %.0f %.0f %.0f\n", gMarioState->pos[0], gMarioState->pos[1], gMarioState->pos[2]);
    CHECK(gCurrAreaIndex == 1 && hypotf(gMarioState->pos[0] + 2400, gMarioState->pos[2] - 4400) < 1500
          && fabsf(gMarioState->pos[1] - 260) < 1.f, "by the first pipe, on the grass");

    CHECK(through_pipe(-2400, 260, 4400, 2), "and through it again");
    CHECK(stage_boxes() == stage_mosaic_boxes(), "the picture laid out again (%d boxes)", stage_boxes());

    printf(failures ? "FAILED (%d failures)\n" : "PASSED (%d failures)\n", failures);
    return failures != 0;
}
