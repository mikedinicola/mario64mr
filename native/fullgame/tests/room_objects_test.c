/* Headless test of enemies carried out into the room (unity_room_objects.inc.h): a Goomba and a Koopa pinched in
 * Castle Grounds, carried out, put on a table and left to walk there, then back into the game every way they go back.
 * Run by run_room_objects_test.sh, against the game library built with no host. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ultra64.h>
#include "sm64.h"
#include "types.h"
#include "object_fields.h"
#include "model_ids.h"
#include "behavior_data.h"
#include "game/object_list_processor.h"
#include "game/spawn_object.h"
#include "game/level_update.h"
#include "game/area.h"
#include "game/object_helpers.h"
#include "pc/cliopts.h"
#include "pc/unity_options.h"

int sm64unity_init(const char *);
int sm64unity_tick(uint16_t, int8_t, int8_t);
int sm64unity_stage(void);
void sm64unity_cursor(int, float, float);
void sm64unity_mr_geometry(int);
int sm64unity_room_mesh(const s16 *, int);
float sm64unity_room_floor(float, float, float);
int sm64unity_object_grab(float, float, float, float);
int sm64unity_object_hold(float, float, float);
void sm64unity_object_release(float, float, float);
int sm64unity_object_hold_room(float, float, float);
int sm64unity_object_release_room(float, float, float);
int sm64unity_object_grab_room(float, float, float, float);
int sm64unity_room_objects(float *, int);
int sm64unity_room_object_return(int, float, float, float, float, float, float);
void sm64unity_room_objects_return(void);
const int *sm64unity_tags(void);
struct UnityBatch { uint32_t a; int b, c, triangles; uint32_t d, e; int f[4]; int g[4], h[4]; int i[6]; };
const struct UnityBatch *sm64unity_batches(int *);
int sm64unity_render_current(void);
void unity_room_objects_warped(void);
int sm64unity_game_hands(const s16 *, int);
int unity_object_in_room(struct Object *);

static int failures;
#define CHECK(c, ...) do { if (c) printf("  ok   " __VA_ARGS__); else { printf("  FAIL " __VA_ARGS__); failures++; } printf("\n"); } while (0)

static void tick(uint16_t b) { sm64unity_tick(b, 0, 0); sm64unity_render_current(); }
static void ticks(int n) { for (int i = 0; i < n; i++) tick(0); }

/* Tags in the last frame's draws: how many batches with each */
static void tag_counts(int counts[8]) {
    memset(counts, 0, 8 * sizeof(int));
    int n; sm64unity_batches(&n);
    const int *tags = sm64unity_tags();
    for (int i = 0; i < n; i++) if (tags[i] >= 0 && tags[i] < 8) counts[tags[i]]++;
}

/* A flat rectangle (two floor triangles, wound up) at height y */
static int quad(s16 *t, float x0, float z0, float x1, float z1, float y) {
    s16 v[] = { x0, y, z0, x0, y, z1, x1, y, z1, x0, y, z0, x1, y, z1, x1, y, z0 };
    memcpy(t, v, sizeof(v));
    return 2;
}
/* A wall (two triangles) from (x0, z0) to (x1, z1), y0 to y1, both windings (a thin box side) */
static int wall(s16 *t, float x0, float z0, float x1, float z1, float y0, float y1) {
    s16 v[] = { x0, y0, z0, x1, y0, z1, x1, y1, z1, x0, y0, z0, x1, y1, z1, x0, y1, z0,
                x1, y1, z1, x1, y0, z1, x0, y0, z0, x0, y1, z0, x1, y1, z1, x0, y0, z0 };
    memcpy(t, v, sizeof(v));
    return 4;
}

/* The room: a floor, and a table 1.5 m by 1 m, 0.75 m high (600 units a metre), its top at 450 */
#define TABLE_Y 450.f
static s16 room[64 * 9];
static int room_count;
static void load_room(void) {
    room_count = 0;
    room_count += quad(room + room_count * 9, -3000, -3000, 3000, 3000, 0);
    room_count += quad(room + room_count * 9, 1000, -300, 1900, 300, TABLE_Y);
    room_count += wall(room + room_count * 9, 1000, -300, 1900, -300, 0, TABLE_Y);
    room_count += wall(room + room_count * 9, 1000, 300, 1900, 300, 0, TABLE_Y);
    room_count += wall(room + room_count * 9, 1000, -300, 1000, 300, 0, TABLE_Y);
    room_count += wall(room + room_count * 9, 1900, -300, 1900, 300, 0, TABLE_Y);
    int loaded = sm64unity_room_mesh(room, room_count);
    float table = sm64unity_room_floor(1450, 600, 0), floor = sm64unity_room_floor(0, 100, 0);
    printf("room: %d surfaces, table top %.0f, floor %.0f\n", loaded, table, floor);
}

static struct Object *spawn(const BehaviorScript *bhv, int model, float dx, float dz) {
    struct Object *o = spawn_object(gMarioObject, model, bhv);
    o->oPosX = gMarioObject->oPosX + dx; o->oPosY = gMarioObject->oPosY + 50; o->oPosZ = gMarioObject->oPosZ + dz;
    o->oHomeX = o->oPosX; o->oHomeY = o->oPosY; o->oHomeZ = o->oPosZ;
    o->parentObj = o;
    o->oBehParams = 0; o->oBehParams2ndByte = 0;
    return o;
}

static int on_table(struct Object *o) {
    return o->oPosX >= 990 && o->oPosX <= 1910 && o->oPosZ >= -310 && o->oPosZ <= 310 && o->oPosY >= TABLE_Y - 5 && o->oPosY < TABLE_Y + 400; /* (on it, or jumping) */
}

/* Carry o out, set it on the table, watch it live there */
static void out_onto_table(const char *name, struct Object *o) {
    printf("%s:\n", name);
    float home[3] = { o->oHomeX, o->oHomeY, o->oHomeZ }, from[3] = { o->oPosX, o->oPosY, o->oPosZ };
    struct Object *parent = o->parentObj;
    CHECK(sm64unity_object_grab(o->oPosX, o->oPosY + 20, o->oPosZ, 30) == 1, "pinched in the game");
    CHECK(sm64unity_object_hold(o->oPosX, o->oPosY + 40, o->oPosZ) == 1, "held in the game");
    tick(0);
    CHECK(!unity_object_in_room(o), "not in the room yet");
    CHECK(sm64unity_object_hold_room(1450, 700, 0) == 1, "carried out of the window");
    CHECK(unity_object_in_room(o), "in the room");
    tick(0);
    CHECK(fabsf(o->oPosX - 1450) < 1 && fabsf(o->oPosZ) < 1 && o->oPosY > TABLE_Y, "hangs from the pinch in the room (%.0f %.0f %.0f)",
          o->oPosX, o->oPosY, o->oPosZ);
    int counts[8]; tag_counts(counts);
    if (!o->header.gfx.sharedChild) printf("  (no model loaded here: nothing to draw)\n");
    else CHECK(counts[4] > 0, "drawn tagged 4 for the room (%d draws)", counts[4]);
    if (o->header.gfx.sharedChild) CHECK(counts[5] > 0, "its shadow tagged 5, on the table under it (%d draws)", counts[5]);
    float out[32];
    int n = sm64unity_room_objects(out, 4);
    CHECK(n == 1 && out[1] == 1, "listed out in the room, held");
    sm64unity_object_hold_room(1450, 650, 0); tick(0);
    CHECK(sm64unity_object_release_room(0, 0, 0) == 1, "put down over the table");
    CHECK(o->oHomeX == 1450 && fabsf(o->oHomeY - TABLE_Y) < 1, "its home is the table now (%.0f %.0f %.0f)", o->oHomeX, o->oHomeY, o->oHomeZ);
    ticks(30);
    CHECK(on_table(o), "landed on the table (%.0f %.0f %.0f)", o->oPosX, o->oPosY, o->oPosZ);
    float minx = 1e9, maxx = -1e9, minz = 1e9, maxz = -1e9;
    int stayed = 1, active = 1, untouched = 1;
    for (int i = 0; i < 600; i++) {
        tick(0);
        if (!(o->activeFlags & ACTIVE_FLAG_ACTIVE)) { active = 0; break; }
        if (!on_table(o) || !unity_object_in_room(o)) stayed = 0;
        if (o->activeFlags & ACTIVE_FLAG_FAR_AWAY || !(o->header.gfx.node.flags & GRAPH_RENDER_ACTIVE)) active = 0;
        if (o->numCollidedObjs) untouched = 0;
        if (o->oPosX < minx) minx = o->oPosX; if (o->oPosX > maxx) maxx = o->oPosX;
        if (o->oPosZ < minz) minz = o->oPosZ; if (o->oPosZ > maxz) maxz = o->oPosZ;
    }
    CHECK(active, "kept active, near and drawn for 20 s far from Mario");
    CHECK(stayed, "stayed on the table");
    CHECK(maxx - minx > 20 || maxz - minz > 20, "walked about on it (x %.0f..%.0f, z %.0f..%.0f)", minx, maxx, minz, maxz);
    CHECK(untouched, "touched nothing");
    CHECK(o->parentObj == o, "nobody's child out there");

    /* Picked up again out there and held where Mario is in the level: nothing touches */
    s16 health = gMarioState->health;
    CHECK(sm64unity_object_grab_room(o->oPosX, o->oPosY + 20, o->oPosZ, 30) == 1, "pinched again in the room");
    untouched = 1;
    for (int i = 0; i < 30; i++) {
        sm64unity_object_hold_room(gMarioObject->oPosX, gMarioObject->oPosY + 60, gMarioObject->oPosZ);
        tick(0);
        if (o->numCollidedObjs) untouched = 0;
        for (int k = 0; k < gMarioObject->numCollidedObjs; k++) if (gMarioObject->collidedObjs[k] == o) untouched = 0;
    }
    (void) health;
    CHECK(untouched, "held where Mario is in the level: neither touches the other");
    sm64unity_object_hold_room(1450, 650, 0); tick(0);
    sm64unity_object_release_room(0, 0, 0);
    ticks(30);

    /* Walking back through the window (the host finds it there): back in the level, its own home again */
    n = sm64unity_room_objects(out, 4);
    CHECK(n == 1 && out[1] == 0, "listed, not held");
    float at[3] = { gMarioObject->oPosX + 300, gMarioObject->oPosY + 20, gMarioObject->oPosZ };
    CHECK(sm64unity_room_object_return((int) out[0], at[0], at[1], at[2], 5, 0, 0) == 1, "walked back into the game");
    CHECK(!unity_object_in_room(o) && sm64unity_room_objects(out, 4) == 0, "out of the room");
    CHECK(o->oHomeX == home[0] && o->oHomeY == home[1] && o->oHomeZ == home[2], "its home in the level again");
    CHECK(o->parentObj == parent, "its spawner's again");
    ticks(10);
    tag_counts(counts);
    CHECK(counts[4] == 0 && counts[5] == 0, "drawn in the level again");
    CHECK(fabsf(o->oPosX - at[0]) < 300 && fabsf(o->oPosY - at[1]) < 300, "in the level where it came in (%.0f %.0f %.0f)",
          o->oPosX, o->oPosY, o->oPosZ);
    (void) from;
}

/* A palm slapped straight down through (x, z), game coordinates, from well above y to below it. 1 if o was squashed
 * (gone within a few seconds after) */
static int slap(struct Object *o, float x, float y, float z) {
    for (float h = y + 300; h > y - 100; h -= 40) {
        s16 palm[18];
        quad(palm, x - 80, z - 80, x + 80, z + 80, h);
        sm64unity_game_hands(palm, 2);
        tick(0);
    }
    sm64unity_game_hands(NULL, 0);
    for (int i = 0; i < 150 && (o->activeFlags & ACTIVE_FLAG_ACTIVE); i++) tick(0);
    return !(o->activeFlags & ACTIVE_FLAG_ACTIVE);
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
    printf("Castle Grounds, Mario at %.0f %.0f %.0f\n", gMarioObject->oPosX, gMarioObject->oPosY, gMarioObject->oPosZ);
    load_room();

    struct Object *goomba = spawn(bhvGoomba, MODEL_GOOMBA, 600, 600);
    ticks(30);
    out_onto_table("Goomba", goomba);

    struct Object *koopa = spawn(bhvKoopa, MODEL_KOOPA_WITH_SHELL, -600, 600);
    koopa->oBehParams2ndByte = KOOPA_BP_NORMAL;
    ticks(30);
    if (koopa->activeFlags & ACTIVE_FLAG_ACTIVE) out_onto_table("Koopa", koopa);

    printf("Carried back in through the window:\n");
    struct Object *o = goomba;
    float home[3] = { o->oHomeX, o->oHomeY, o->oHomeZ };
    sm64unity_object_grab(o->oPosX, o->oPosY + 20, o->oPosZ, 30);
    sm64unity_object_hold_room(1450, 700, 0); tick(0);
    CHECK(unity_object_in_room(o), "out");
    CHECK(sm64unity_object_hold(gMarioObject->oPosX + 200, gMarioObject->oPosY + 150, gMarioObject->oPosZ) == 1, "held back through the window");
    CHECK(!unity_object_in_room(o) && o->oHomeX == home[0], "back in the game, its home again");
    sm64unity_object_release(0, 0, 0);
    ticks(30);
    CHECK(o->oPosY < gMarioObject->oPosY + 100, "dropped there, fell to the ground (%.0f, Mario %.0f)", o->oPosY, gMarioObject->oPosY);

    printf("Let go of with nothing under it:\n");
    float from[3] = { o->oPosX, o->oPosY, o->oPosZ };
    sm64unity_object_grab(o->oPosX, o->oPosY + 20, o->oPosZ, 30);
    sm64unity_object_hold_room(5000, 700, 5000); tick(0);
    CHECK(sm64unity_object_release_room(0, 0, 0) == 0, "not put down off the room");
    CHECK(!unity_object_in_room(o) && fabsf(o->oPosX - from[0]) < 1 && fabsf(o->oPosZ - from[2]) < 1, "back where it was picked up");

    printf("Walked off the scanned room:\n");
    sm64unity_object_grab(o->oPosX, o->oPosY + 20, o->oPosZ, 30);
    sm64unity_object_hold_room(1450, 650, 0); tick(0);
    sm64unity_object_release_room(0, 0, 0); ticks(10);
    CHECK(unity_object_in_room(o), "out on the table");
    sm64unity_room_mesh(NULL, 0); /* (the room forgotten under it) */
    ticks(2);
    CHECK(!unity_object_in_room(o) && fabsf(o->oPosX - from[0]) < 300, "back in the game where it was picked up");
    load_room();

    printf("A warp:\n");
    sm64unity_object_grab(o->oPosX, o->oPosY + 20, o->oPosZ, 30);
    sm64unity_object_hold_room(1450, 650, 0); tick(0);
    sm64unity_object_release_room(0, 0, 0); ticks(10);
    CHECK(unity_object_in_room(o), "out on the table");
    unity_room_objects_warped();
    CHECK(!unity_object_in_room(o), "back in the game");
    CHECK(sm64unity_object_hold(0, 0, 0) == 0, "and not held");

    printf("Leaving the room (MarioCarrier.reset):\n");
    sm64unity_object_grab(o->oPosX, o->oPosY + 20, o->oPosZ, 30);
    sm64unity_object_hold_room(1450, 650, 0); tick(0);
    sm64unity_object_release_room(0, 0, 0); ticks(5);
    sm64unity_room_objects_return();
    CHECK(!unity_object_in_room(o), "back in the game");

    printf("Squash with your palm:\n");
    struct Object *g = spawn(bhvGoomba, MODEL_GOOMBA, 0, 900);
    ticks(30);
    sm64unity_object_grab(g->oPosX, g->oPosY + 20, g->oPosZ, 30);
    sm64unity_object_hold_room(1450, 650, 0); tick(0);
    sm64unity_object_release_room(0, 0, 0); ticks(20);
    CHECK(unity_object_in_room(g), "a Goomba out on the table");
    /* (a hand in the game, slapping where its room coordinates would be in the level) */
    CHECK(!slap(g, g->oPosX, g->oPosY, g->oPosZ) && unity_object_in_room(g), "a slap in the game doesn't squash it out there");
    float out[32];
    sm64unity_room_objects(out, 4);
    sm64unity_room_object_return((int) out[0], gMarioObject->oPosX, gMarioObject->oPosY + 20, gMarioObject->oPosZ + 900, 0, 0, 0);
    ticks(30);
    CHECK(slap(g, g->oPosX, g->oPosY, g->oPosZ), "back in the game, a slap squashes it");

    printf("Excluded: a Thwomp can't be pinched\n");
    struct Object *t = spawn(bhvThwomp, MODEL_NONE, 0, -900);
    ticks(2);
    CHECK(sm64unity_object_grab(t->oPosX, t->oPosY + 20, t->oPosZ, 30) == 0, "not picked up");

    printf("The Cheats menu's hand switches, off:\n");
    gUnityHandCheats[UNITY_HAND_PICK_UP] = 0;
    struct Object *k = spawn(bhvGoomba, MODEL_GOOMBA, 300, 900);
    ticks(30);
    CHECK(sm64unity_object_grab(k->oPosX, k->oPosY + 20, k->oPosZ, 30) == 0, "Hands pick up enemies off: not picked up");
    gUnityHandCheats[UNITY_HAND_SQUASH] = 0;
    CHECK(!slap(k, k->oPosX, k->oPosY, k->oPosZ), "Hands squash off: a slap doesn't squash it");
    gUnityHandCheats[UNITY_HAND_SQUASH] = 1;
    gUnityHandCheats[UNITY_HAND_PICK_UP] = 1;
    ticks(2);
    CHECK(gUnityOptions[UNITY_OPT_HAND_CHEATS] == 7, "back on, kept with the options (%u)", gUnityOptions[UNITY_OPT_HAND_CHEATS]);

    ticks(60);
    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures != 0;
}
