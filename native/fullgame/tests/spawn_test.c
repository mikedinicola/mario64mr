/* Headless test of the treasure chest (unity_spawn.inc.h): enemies and power-up boxes taken out with a pinch in the
 * room or the level, or with a look near Mario; boxes floating at a jump's height and broken by one; and more Marios
 * (unity_marios.inc.h) running with the same stick; and the chest itself, the game's own (unity_chest.inc.h). In
 * Castle Grounds. Run by run_room_objects_test.sh
 * (TEST=spawn_test), against the game library built with no host. */
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
#include "game/level_update.h"
#include "game/area.h"
#include "game/object_helpers.h"
#include "game/camera.h"
#include "engine/math_util.h"
#include "engine/surface_collision.h"
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
int sm64unity_room_objects(float *, int);
void sm64unity_room_objects_return(void);
int sm64unity_render_current(void);
int unity_object_in_room(struct Object *);
unsigned int sm64unity_spawn_available(void);
int sm64unity_spawn_held(int kind, int in_room, float x, float y, float z);
int sm64unity_spawn_near_mario(int kind);
int sm64unity_carry(int, float, float, float, float, float, float);
int sm64unity_marios(float *out, int max);
void unity_mario_warped(void);
extern const BehaviorScript bhvUnityMario[];
void sm64unity_chest(int show, float x, float y, float z, float yaw, float lid, float scale);
int unity_chest_part(struct Object *o);
int unity_graph_tag(struct GraphNodeObject *node, int shadow);

enum { GOOMBA, BOBOMB, KOOPA, CHUCKYA, BULLY, WING_BOX, METAL_BOX, VANISH_BOX, COIN_BOX, ONE_UP_BOX, MARIO, SHELL, KINDS };
static const char *names[] = { "Goomba", "Bob-omb", "Koopa", "Chuckya", "Bully", "wing cap box", "metal cap box",
                               "vanish cap box", "coin box", "1-up box", "Mario",
                               "Koopa shell" };

static int failures;
#define CHECK(c, ...) do { if (c) printf("  ok   " __VA_ARGS__); else { printf("  FAIL " __VA_ARGS__); failures++; } printf("\n"); } while (0)

static void tick(uint16_t b) { sm64unity_tick(b, 0, 0); sm64unity_render_current(); }
static void ticks(int n) { for (int i = 0; i < n; i++) tick(0); }
static void tick_stick(uint16_t b, int8_t x, int8_t y) { sm64unity_tick(b, x, y); sm64unity_render_current(); }

static int quad(s16 *t, float x0, float z0, float x1, float z1, float y) {
    s16 v[] = { x0, y, z0, x0, y, z1, x1, y, z1, x0, y, z0, x1, y, z1, x1, y, z0 };
    memcpy(t, v, sizeof(v));
    return 2;
}
#define TABLE_Y 450.f
static void load_room(void) {
    static s16 room[16 * 9];
    int n = 0;
    n += quad(room + n * 9, -3000, -3000, 3000, 3000, 0);
    n += quad(room + n * 9, 1000, -300, 1900, 300, TABLE_Y);
    sm64unity_room_mesh(room, n);
}

/* The object last made with this behaviour (what the chest just made) */
static struct Object *newest(const BehaviorScript *bhv) {
    struct Object *found = NULL;
    for (int l = 0; l < NUM_OBJ_LISTS; l++) {
        struct ObjectNode *head = &gObjectLists[l];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node;
            if (o->behavior == segmented_to_virtual(bhv) && (o->activeFlags & ACTIVE_FLAG_ACTIVE)) found = o;
        }
    }
    return found;
}
static int count(const BehaviorScript *bhv) {
    int n = 0;
    for (int l = 0; l < NUM_OBJ_LISTS; l++) {
        struct ObjectNode *head = &gObjectLists[l];
        for (struct ObjectNode *node = head->next; node != head; node = node->next) {
            struct Object *o = (struct Object *) node;
            if (o->behavior == segmented_to_virtual(bhv) && (o->activeFlags & ACTIVE_FLAG_ACTIVE)) n++;
        }
    }
    return n;
}
static float level_floor(float x, float y, float z) {
    struct Surface *s;
    return find_floor(x, y, z, &s);
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
    float start[3] = { gMarioState->pos[0], gMarioState->pos[1], gMarioState->pos[2] };
    load_room();

    unsigned int mask = sm64unity_spawn_available();
    printf("Can spawn here:");
    for (int k = 0; k < KINDS; k++) if (mask & (1u << k)) printf(" %s", names[k]);
    printf("\n");
    CHECK(mask & (1u << GOOMBA), "a Goomba");
    CHECK(mask & (1u << COIN_BOX), "a coin box");
    CHECK(mask & (1u << SHELL), "a Koopa shell");

    printf("The Cheats menu's Treasure chest, off:\n");
    gUnityHandCheats[UNITY_HAND_CHEST] = 0;
    ticks(2);
    CHECK(sm64unity_spawn_available() == 0, "nothing on offer (so no chest)");
    CHECK(sm64unity_spawn_near_mario(GOOMBA) == 0, "nothing made");
    CHECK(gUnityOptions[UNITY_OPT_HAND_CHEATS] == (7u | UNITY_HAND_CHEATS_INVERTED), "kept off (%u)",
          gUnityOptions[UNITY_OPT_HAND_CHEATS]);
    gUnityHandCheats[UNITY_HAND_CHEST] = 1;
    ticks(2);
    CHECK(sm64unity_spawn_available() == mask, "on again, all back");
    CHECK(gUnityOptions[UNITY_OPT_HAND_CHEATS] == 7, "kept as before it was a switch (%u)", gUnityOptions[UNITY_OPT_HAND_CHEATS]);

    printf("A Goomba pinched out of the chest in the room:\n");
    CHECK(sm64unity_spawn_held(GOOMBA, 1, 1450, 700, 0) == 1, "made, held");
    struct Object *g = newest(bhvGoomba);
    CHECK(g && unity_object_in_room(g), "out in the room");
    float out[8 * 16];
    CHECK(sm64unity_room_objects(out, 16) == 1 && out[1] == 1, "listed out in the room, held");
    sm64unity_object_hold_room(1450, 650, 0); tick(0);
    CHECK(fabsf(g->oPosX - 1450) < 1 && g->oPosY > TABLE_Y, "hangs from the pinch (%.0f %.0f %.0f)", g->oPosX, g->oPosY, g->oPosZ);
    CHECK(sm64unity_object_release_room(0, 0, 0) == 1, "put down over the table");
    ticks(120);
    CHECK((g->activeFlags & ACTIVE_FLAG_ACTIVE) && unity_object_in_room(g) && fabsf(g->oPosY - TABLE_Y) < 60,
          "lives on the table (%.0f %.0f %.0f)", g->oPosX, g->oPosY, g->oPosZ);
    CHECK(g->parentObj == g, "nobody's child");

    printf("Let go of with nothing under it:\n");
    CHECK(sm64unity_spawn_held(GOOMBA, 1, 1450, 700, 0) == 1, "another made, held");
    struct Object *g2 = newest(bhvGoomba);
    sm64unity_object_hold_room(5000, 700, 5000); tick(0);
    CHECK(sm64unity_object_release_room(0, 0, 0) == 0, "not put down off the room");
    ticks(2);
    CHECK(!(g2->activeFlags & ACTIVE_FLAG_ACTIVE) || g2->behavior != segmented_to_virtual(bhvGoomba), "gone (nowhere in the level to go back to)");

    printf("Carried in through the window:\n");
    CHECK(sm64unity_spawn_held(CHUCKYA, 1, 1450, 700, 0) == 1, "a Chuckya made, held in the room");
    struct Object *k = newest(bhvChuckya);
    if (!k) { printf("no Chuckya\n"); return 1; }
    float at[3] = { gMarioObject->oPosX + 300, gMarioObject->oPosY + 150, gMarioObject->oPosZ };
    CHECK(sm64unity_object_hold(at[0], at[1], at[2]) == 1 && !unity_object_in_room(k), "in the level now");
    sm64unity_object_release(0, 0, 0);
    ticks(60);
    CHECK((k->activeFlags & ACTIVE_FLAG_ACTIVE) && k->oPosY < at[1], "dropped there, on the ground (%.0f)", k->oPosY);

    printf("A coin box let go of in the level:\n");
    float bx = gMarioObject->oPosX + 400, bz = gMarioObject->oPosZ;
    CHECK(sm64unity_spawn_held(COIN_BOX, 0, bx, gMarioObject->oPosY + 700, bz) == 1, "made, held");
    struct Object *box = newest(bhvExclamationBox);
    tick(0);
    sm64unity_object_release(0, 0, 0);
    ticks(40);
    float floor = level_floor(box->oPosX, box->oPosY, box->oPosZ);
    CHECK(fabsf(box->oPosY - (floor + 260)) < 2, "floats at a jump's height over the floor (%.0f over it)", box->oPosY - floor);
    CHECK(box->oAction == 2, "solid (%d)", box->oAction);

    printf("A wing cap box, its switch not pressed:\n");
    CHECK(sm64unity_spawn_held(WING_BOX, 0, bx + 400, gMarioObject->oPosY + 300, bz) == 1, "made");
    struct Object *wing = newest(bhvExclamationBox);
    sm64unity_object_release(0, 0, 0);
    ticks(20);
    CHECK(wing->oAction == 2, "solid all the same (%d)", wing->oAction);

    printf("Mario jumps into a box over him:\n");
    float mx = gMarioObject->oPosX, my = gMarioObject->oPosY, mz = gMarioObject->oPosZ;
    CHECK(sm64unity_spawn_held(VANISH_BOX, 0, mx, my + 600, mz) == 1, "made over him");
    struct Object *over = newest(bhvExclamationBox);
    sm64unity_object_release(0, 0, 0);
    ticks(40);
    CHECK(fabsf(over->oPosY - (my + 260)) < 20, "over his head (%.0f over him)", over->oPosY - my);
    int broke = 0;
    for (int i = 0; i < 40 && !broke; i++) {
        tick(i < 20 ? A_BUTTON : 0);
        if (!(over->activeFlags & ACTIVE_FLAG_ACTIVE) || over->oAction >= 3) broke = 1;
    }
    CHECK(broke, "broken by his jump (action %d)", over->oAction);
    int cap = 0;
    for (int i = 0; i < 60; i++) { tick(0); if (newest(bhvVanishCap) || (gMarioState->flags & MARIO_VANISH_CAP)) cap = 1; }
    CHECK(cap, "a vanish cap came out of it (on him: %s)", gMarioState->flags & MARIO_VANISH_CAP ? "yes" : "no");
    CHECK(!(over->activeFlags & ACTIVE_FLAG_ACTIVE) || over->behavior != segmented_to_virtual(bhvExclamationBox), "and the box is gone, not back later");

    printf("A box put down in the room:\n");
    CHECK(sm64unity_spawn_held(ONE_UP_BOX, 1, 1450, 900, 100) == 1, "a 1-up box made in the room");
    struct Object *rbox = newest(bhvExclamationBox);
    sm64unity_object_hold_room(1450, 900, 100); tick(0);
    CHECK(sm64unity_object_release_room(0, 0, 0) == 1, "put down over the table");
    ticks(40);
    CHECK(unity_object_in_room(rbox) && fabsf(rbox->oPosY - (TABLE_Y + 260)) < 2, "floats over the table (%.0f over it)", rbox->oPosY - TABLE_Y);

    printf("Taken out with a look:\n");
    int goombas = count(bhvGoomba);
    CHECK(sm64unity_spawn_near_mario(GOOMBA) == 1, "a Goomba near Mario");
    struct Object *near = newest(bhvGoomba);
    CHECK(count(bhvGoomba) == goombas + 1 && !unity_object_in_room(near), "in the level");
    float dx = near->oPosX - gMarioObject->oPosX, dz = near->oPosZ - gMarioObject->oPosZ;
    CHECK(sqrtf(dx * dx + dz * dz) < 300, "a step from him (%.0f)", sqrtf(dx * dx + dz * dz));

    printf("At most six of a kind:\n");
    int made = 0;
    for (int i = 0; i < 10; i++) made += sm64unity_spawn_near_mario(BOBOMB);
    CHECK(made == 6, "six Bob-ombs, not ten (%d)", made);
    CHECK(!(sm64unity_spawn_available() & (1u << BOBOMB)), "no more on offer");

    printf("Mario out in the room jumps into a coin box there:\n");
    CHECK(sm64unity_carry(3, -1500, 20, -1500, 0, 0, 0) == 1, "Mario put down out in the room");
    ticks(30);
    float rx = gMarioState->pos[0], ry = gMarioState->pos[1], rz = gMarioState->pos[2];
    CHECK(sm64unity_spawn_held(COIN_BOX, 1, rx, ry + 600, rz) == 1, "a coin box over him");
    struct Object *cbox = newest(bhvExclamationBox);
    sm64unity_object_hold_room(rx, ry + 600, rz); tick(0);
    CHECK(sm64unity_object_release_room(0, 0, 0) == 1, "let go of over him");
    ticks(40);
    CHECK(unity_object_in_room(cbox) && fabsf(cbox->oPosY - (ry + 260)) < 2, "floats over his head (%.0f over him)", cbox->oPosY - ry);
    s16 coins = gMarioState->numCoins;
    int hit = 0;
    for (int i = 0; i < 40 && !hit; i++) {
        tick(i < 20 ? A_BUTTON : 0);
        if (!(cbox->activeFlags & ACTIVE_FLAG_ACTIVE) || cbox->oAction >= 3) hit = 1;
    }
    CHECK(hit, "broken by his jump out there");
    int outside = 0;
    for (int i = 0; i < 20; i++) {
        tick(0); float o2[8 * 16]; int n = sm64unity_room_objects(o2, 16); if (n > outside) outside = n;
    }
    CHECK(outside >= 1, "what it let out is out in the room (%d out there)", outside);
    ticks(30);
    /* (he stands still: put him where each is, out there) */
    float o3[8 * 16];
    int n3 = sm64unity_room_objects(o3, 16);
    for (int i = 0; i < n3; i++) {
        sm64unity_carry(3, o3[i * 8 + 2], o3[i * 8 + 3] + 5, o3[i * 8 + 4], 0, 0, 0);
        ticks(3);
    }
    CHECK(gMarioState->numCoins > coins, "he collects its coins out there (%d -> %d)", coins, gMarioState->numCoins);
    sm64unity_carry(0, start[0], start[1] + 50, start[2], 0, 0, 0); /* (back where he started in the level) */

    printf("A Koopa shell, ridden:\n");
    /* (the enemies made so far out of the way, Mario back where he started and standing) */
    {
        const BehaviorScript *enemies[] = { bhvGoomba, bhvBobomb, bhvChuckya };
        for (int e = 0; e < 3; e++)
            for (struct Object *o; (o = newest(enemies[e])) != NULL;) obj_mark_for_deletion(o), o->activeFlags &= ~ACTIVE_FLAG_ACTIVE;
        ticks(2);
        sm64unity_carry(0, start[0], start[1] + 50, start[2], 0, 0, 0);
        ticks(60);
    }
    CHECK(sm64unity_spawn_held(SHELL, 0, gMarioObject->oPosX + 400, gMarioObject->oPosY + 300, gMarioObject->oPosZ) == 1,
          "made, held in the level");
    struct Object *shell = newest(bhvKoopaShell);
    sm64unity_object_release(0, 0, 0);
    ticks(40);
    CHECK(shell && (shell->activeFlags & ACTIVE_FLAG_ACTIVE)
          && fabsf(shell->oPosY - level_floor(shell->oPosX, shell->oPosY + 50, shell->oPosZ)) < 10,
          "on the ground (%.0f over it)", shell ? shell->oPosY - level_floor(shell->oPosX, shell->oPosY + 50, shell->oPosZ) : 0);
    CHECK(sm64unity_object_grab(shell->oPosX, shell->oPosY + 20, shell->oPosZ, 100) == 1, "picked up again by a pinch");
    sm64unity_object_release(0, 0, 0);
    ticks(40);
    CHECK(sm64unity_spawn_near_mario(SHELL) == 1, "another put down in front of Mario");
    struct Object *ride = newest(bhvKoopaShell);
    int riding = 0;
    for (int i = 0; i < 60 && !riding; i++) {
        /* (walk at it) */
        float dx = ride->oPosX - gMarioState->pos[0], dz = ride->oPosZ - gMarioState->pos[2];
        s16 to = atan2s(dz, dx) - gCamera->yaw;
        tick_stick(0, (int8_t) (sins(to) * 64), (int8_t) (-coss(to) * 64));
        riding = (gMarioState->action & ACT_FLAG_RIDING_SHELL) && gMarioState->riddenObj == ride;
    }
    CHECK(riding, "Mario walks into it and rides it (action %08x)", gMarioState->action);
    for (int i = 0; i < 30; i++) tick_stick(0, 0, 80);
    float sdx = ride->oPosX - gMarioState->pos[0], sdz = ride->oPosZ - gMarioState->pos[2];
    CHECK(sqrtf(sdx * sdx + sdz * sdz) < 1, "it goes where he goes");
    CHECK(sm64unity_object_grab(ride->oPosX, ride->oPosY + 20, ride->oPosZ, 200) == 0, "not the hands' to take while he rides it");
    for (int i = 0; i < 10; i++) tick(Z_TRIG);
    ticks(30);
    CHECK(!(gMarioState->action & ACT_FLAG_RIDING_SHELL), "off it with Z (action %08x)", gMarioState->action);
    CHECK(!(ride->activeFlags & ACTIVE_FLAG_ACTIVE) || ride->behavior != segmented_to_virtual(bhvKoopaShell), "and it's gone");
    sm64unity_carry(0, start[0], start[1] + 50, start[2], 0, 0, 0);
    ticks(60);

    printf("More Marios:\n");
    ticks(60);
    CHECK(sm64unity_spawn_available() & (1u << MARIO), "on offer");
    int marios = 0;
    for (int i = 0; i < 5; i++) { marios += sm64unity_spawn_near_mario(MARIO); ticks(5); }
    CHECK(marios == 3, "three of them, not five (%d)", marios);
    CHECK(!(sm64unity_spawn_available() & (1u << MARIO)), "no more on offer");
    float at0[12], at1[12];
    CHECK(sm64unity_marios(at0, 3) == 3, "all three there");
    ticks(30);
    CHECK(count(bhvUnityMario) == 3, "three objects with Mario's model (%d)", count(bhvUnityMario));
    float first0[3] = { gMarioState->pos[0], gMarioState->pos[1], gMarioState->pos[2] };
    sm64unity_marios(at0, 3);
    for (int i = 0; i < 30; i++) { sm64unity_tick(0, 0, 80); sm64unity_render_current(); }
    int moved = sm64unity_marios(at1, 3) == 3;
    for (int k = 0; k < 3 && moved; k++) {
        float dx = at1[k * 4] - at0[k * 4], dz = at1[k * 4 + 2] - at0[k * 4 + 2];
        if (sqrtf(dx * dx + dz * dz) < 150) moved = 0;
        printf("    Mario %d ran %.0f\n", k + 2, sqrtf(dx * dx + dz * dz));
    }
    float fdx = gMarioState->pos[0] - first0[0], fdz = gMarioState->pos[2] - first0[2];
    printf("    the first ran %.0f\n", sqrtf(fdx * fdx + fdz * fdz));
    CHECK(moved, "they all ran with the stick");
    for (int i = 0; i < 20; i++) tick(0);
    sm64unity_marios(at0, 3);
    float top[3] = { -1e9, -1e9, -1e9 };
    for (int i = 0; i < 25; i++) {
        tick(i < 12 ? A_BUTTON : 0);
        sm64unity_marios(at1, 3);
        for (int k = 0; k < 3; k++) if (at1[k * 4 + 1] - at0[k * 4 + 1] > top[k]) top[k] = at1[k * 4 + 1] - at0[k * 4 + 1];
    }
    CHECK(top[0] > 100 && top[1] > 100 && top[2] > 100, "and all jumped with A (%.0f %.0f %.0f up)", top[0], top[1], top[2]);
    {
        int stand = 1;
        for (struct Object *o = (struct Object *) gObjectLists[OBJ_LIST_PLAYER].next;
             o != (struct Object *) &gObjectLists[OBJ_LIST_PLAYER]; o = (struct Object *) o->header.next)
            if (o != gMarioObject && o->header.gfx.unk38.animYTrans != gMarioObject->header.gfx.unk38.animYTrans) stand = 0;
        CHECK(stand, "and stand as high as he does (animations at %d)", gMarioObject->header.gfx.unk38.animYTrans);
    }
    ticks(40);  /* (landed and still: Z crouches) */
    for (int i = 0; i < 10; i++) tick(Z_TRIG);
    for (int i = 0; i < 20; i++) tick_stick(Z_TRIG, 0, 80);
    {   /* Tilted to the floor, crawling: the first Mario's tilt is his (an extra one's step used to overwrite it, and
         * they were all drawn where the last one was) */
        extern Mat4 sFloorAlignMatrix[2];
        float *t = sFloorAlignMatrix[0][3];
        sm64unity_marios(at1, 3);
        int extra = 0;
        for (int k = 0; k < 3; k++)
            if (fabsf(sFloorAlignMatrix[1][3][0] - at1[k * 4]) < 1 && fabsf(sFloorAlignMatrix[1][3][2] - at1[k * 4 + 2]) < 1) extra = 1;
        CHECK(gMarioState->action == ACT_CRAWLING, "crawling with Z and the stick");
        CHECK(fabsf(t[0] - gMarioState->pos[0]) < 1 && fabsf(t[2] - gMarioState->pos[2]) < 1,
              "the first one tilted where he is (%.0f %.0f, at %.0f %.0f)", t[0], t[2], gMarioState->pos[0], gMarioState->pos[2]);
        CHECK(extra, "the others' tilt their own (player 2's, copied out)");
    }
    for (int i = 0; i < 20; i++) tick(0);
    CHECK(gCurrLevelNum == LEVEL_CASTLE_GROUNDS && gMarioState->action, "the first one's still playing");
    ticks(30);
    sm64unity_marios(at1, 3);
    s16 before = gMarioState->numCoins;
    struct Object *coin = spawn_object(gMarioObject, MODEL_YELLOW_COIN, bhvYellowCoin);
    coin->oPosX = at1[0]; coin->oPosY = at1[1] + 40; coin->oPosZ = at1[2];
    ticks(5);
    CHECK(gMarioState->numCoins == before + 1, "a coin the second one runs into counts for the first (%d -> %d)", before, gMarioState->numCoins);
    unity_mario_warped();
    tick(0);
    CHECK(sm64unity_marios(at1, 3) == 0 && count(bhvUnityMario) == 0, "a warp: gone");

    printf("The chest, the game's own, in the room:\n");
    {
        struct Object *parts[3] = { 0 };
        int n = 0;
        sm64unity_chest(1, 1000, 2000, -500, (float) M_PI / 2, 1.0f, 0.5f);
        ticks(2);
#define CHEST_PARTS() do { n = 0; parts[0] = parts[1] = NULL; for (int l = 0; l < NUM_OBJ_LISTS; l++) { \
            struct ObjectNode *head = &gObjectLists[l]; \
            for (struct ObjectNode *node = head->next; node != head; node = node->next) \
                if (unity_chest_part((struct Object *) node) && n < 3) parts[n++] = (struct Object *) node; } } while (0)
        CHEST_PARTS();
        CHECK(n == 2, "its base and its lid (%d parts)", n);
        if (n == 2) {
            struct Object *base = parts[0]->oPosY < parts[1]->oPosY ? parts[0] : parts[1], *lid = base == parts[0] ? parts[1] : parts[0];
            CHECK(base->header.gfx.sharedChild && lid->header.gfx.sharedChild && base->header.gfx.sharedChild != lid->header.gfx.sharedChild,
                  "each with its model");
            CHECK(fabsf(base->oPosX - 1000) < 0.5f && fabsf(base->oPosY - 2000) < 0.5f && fabsf(base->oPosZ + 500) < 0.5f
                  && (u16) base->oFaceAngleYaw == 0x4000 && fabsf(base->header.gfx.scale[0] - 0.5f) < 1e-4f,
                  "the base where the host says, turned and scaled (%.0f %.0f %.0f, yaw %04x)", base->oPosX, base->oPosY,
                  base->oPosZ, (u16) base->oFaceAngleYaw);
            CHECK(fabsf(lid->oPosX - (1000 - 38.5f)) < 1 && fabsf(lid->oPosY - 2051) < 1 && fabsf(lid->oPosZ + 500) < 1
                  && abs(lid->oFaceAnglePitch + 10430) < 4, "the lid on its hinge, open (%.0f %.0f %.0f, pitch %d)",
                  lid->oPosX, lid->oPosY, lid->oPosZ, lid->oFaceAnglePitch);
            CHECK(unity_graph_tag(&base->header.gfx, 0) == 4 && unity_graph_tag(&lid->header.gfx, 0) == 4, "drawn in the room (tag 4)");
            obj_mark_for_deletion(lid);
            ticks(2);
            CHEST_PARTS();
            CHECK(n == 2, "unloaded, made again (%d parts)", n);
        }
        sm64unity_chest(0, 0, 0, 0, 0, 0, 1);
        ticks(2);
        CHEST_PARTS();
        CHECK(n == 0, "hidden, gone (%d parts)", n);
#undef CHEST_PARTS
    }

    printf("Leaving the room:\n");
    sm64unity_room_objects_return();
    tick(0);
    CHECK(!(g->activeFlags & ACTIVE_FLAG_ACTIVE) || g->behavior != segmented_to_virtual(bhvGoomba), "the Goomba out there is gone");
    CHECK(sm64unity_room_objects(out, 16) == 0, "nothing out in the room");

    ticks(30);
    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures != 0;
}
