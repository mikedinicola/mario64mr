/* How long the disc stage takes with all its Marios (one out of every box, 128 at most): the game's step and a frame's
 * drawing, timed apart, and how many batches and vertex floats the host gets. With STAGE_SNAPSHOTS=<dir>, the same
 * frame drawn with its batches joined and not (unity_bridge.c, end_frame), as pictures to compare. Run by
 * run_room_objects_test.sh (TEST=perf_stage <scratch> [work] [base.zip], or with a number of Marios after them). */
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
extern int unity_join_batches;
#include "engine/math_util.h"
#include "engine/surface_collision.h"
#include "snapshot.h"
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

#include <stdlib.h>

static void tick(uint16_t b) { sm64unity_tick(b, 0, 0); sm64unity_render_current(); }
static void ticks(int n) { for (int i = 0; i < n; i++) tick(0); }
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
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
static void measure(const char *what, int frames) {
    double tick_ms = 0, render_ms = 0;
    for (int i = 0; i < frames; i++) {
        double a = now_ms(); sm64unity_tick(0, 0, 0);
        double b = now_ms(); sm64unity_render_current();
        double c = now_ms();
        tick_ms += b - a; render_ms += c - b;
    }
    int nb = 0, nf = 0; sm64unity_batches(&nb); sm64unity_vertices(&nf);
    printf("%-28s %3d Marios: tick (step + a drawn frame) %.2f ms, a drawn frame %.2f ms -> step ~%.2f ms; %d batches, %d floats\n",
           what, stage_npcs(), tick_ms / frames, render_ms / frames, (tick_ms - render_ms) / frames, nb, nf);
    fflush(stdout);
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
    ticks(200);
    stage_npcs_fetch(0);
    if (!through_pipe(-2400, 260, 4400, 2)) { printf("no stage\n"); return 1; }
    ticks(60);
    measure("the stage, Mario alone", 300);
    const BehaviorScript *boxes = segmented_to_virtual(bhvStageBox);
    int want = argc > 2 ? atoi(argv[2]) : 128;
    for (struct Object *b = (struct Object *) gObjectLists[OBJ_LIST_DESTRUCTIVE].next;
         b != (struct Object *) &gObjectLists[OBJ_LIST_DESTRUCTIVE] && stage_npcs() < want; b = (struct Object *) b->header.next)
        if (b->behavior == boxes && !b->oAction) { b->oAction = 1; stage_box_mario(b); }
    ticks(60);
    measure("all of them", 300);
    if (getenv("PERF_SPIN")) { printf("spinning\n"); fflush(stdout); for (;;) tick(0); }
    stage_npcs_pause(1);
    ticks(30);
    measure("paused (standing)", 300);
    /* The same frame drawn again with its batches joined and not: the same picture */
    const char *dir = getenv("STAGE_SNAPSHOTS");
    if (dir) {
        char path[1024];
        float eye[3] = { 2600, 2800, 5200 }, at[3] = { 0, 0, -300 };
        for (int join = 0; join < 2; join++) {
            unity_join_batches = join;
            sm64unity_render_current();
            int nb; sm64unity_batches(&nb);
            snprintf(path, sizeof(path), "%s/game-%d.png", dir, join); snapshot(path, 960, 540);
            snprintf(path, sizeof(path), "%s/over-%d.png", dir, join); snapshot_from(path, 960, 540, eye, at);
            printf("pictures, joined %d: %d batches\n", join, nb);
        }
        unity_join_batches = 1;
    }
    return 0;
}
