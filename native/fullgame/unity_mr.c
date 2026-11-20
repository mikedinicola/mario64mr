/* New hand/room interaction only. Ordinary gameplay still executes upstream. */
#include <ultra64.h>
#include <math.h>
#include <string.h>
#include "sm64.h"
#include "game/mario.h"
#include "mario_animation_ids.h"
#include "game/level_update.h"
#include "game/camera.h"
#include "game/area.h"
#include "game/object_list_processor.h"
#include "engine/math_util.h"
#include "engine/surface_collision.h"
#include "pc/configfile.h"
#include "pc/unity_options.h"
#include "pc/cheats.h"

#define EXPORT __attribute__((visibility("default")))

/* The options menu's values (unity_options.h); Unity sets them from what it kept as the game starts */
unsigned int gUnityOptions[UNITY_OPT_COUNT] = { 2, 3, 2, 2, 4, 0, 0, 0, 127, 127, 127, 127, 1, 0, 1,
                                                ((1u << UNITY_HAND_CHEAT_COUNT) - 1) ^ UNITY_HAND_CHEATS_INVERTED, 0, 0 };
bool gUnityHandCheats[UNITY_HAND_CHEAT_COUNT];
int unity_hand_cheat(int which) { return Cheats.EnableCheats && gUnityHandCheats[which]; }
EXPORT unsigned int *sm64unity_options(void) { return gUnityOptions; }
EXPORT int sm64unity_option_count(void) { return UNITY_OPT_COUNT; }

/* The sky the last tick drew (skybox.c): its background (sSkyboxTextures' order: water, bitfs, wdw, cloud_floor, ccm,
 * ssl, bbh, bidw, clouds, bits) and colour (0 JRB's dark green, 1 none), or -1 when it drew none. Unity draws the
 * whole of it as a dome round the game, in place of the tiles in front of the camera */
static int sky_background = -1, sky_color = 1, sky_seen;
void unity_note_sky(int background, int color) { sky_background = background; sky_color = color; sky_seen = 1; }
/* Billboards (math_util.c's mtxf_billboard: trees, coins, particles) turned to face your head, round the game's up,
 * rather than square to the game camera's view, which you look past through the window or from inside the game.
 * Unity gives your head and the game's up in the camera's view space (where billboards are made) before each tick */
static int billboard_eye;
static float billboard_at[3], billboard_up[3] = { 0, 1, 0 };
EXPORT void sm64unity_billboards(int on, float x, float y, float z, float ux, float uy, float uz) {
    billboard_eye = on;
    billboard_at[0] = x; billboard_at[1] = y; billboard_at[2] = z;
    float n = sqrtf(ux * ux + uy * uy + uz * uz);
    if (n > 1e-6f) { billboard_up[0] = ux / n; billboard_up[1] = uy / n; billboard_up[2] = uz / n; }
}
int unity_billboard(Mat4 dest, Mat4 mtx, Vec3f position, s16 angle) {
    if (!billboard_eye) return 0;
    float t[3];
    for (int i = 0; i < 3; i++)
        t[i] = mtx[0][i] * position[0] + mtx[1][i] * position[1] + mtx[2][i] * position[2] + mtx[3][i];
    const float *u = billboard_up;
    /* Its face (+z) towards the head, level: the way to the head, less its up */
    float f[3] = { billboard_at[0] - t[0], billboard_at[1] - t[1], billboard_at[2] - t[2] };
    float along = f[0] * u[0] + f[1] * u[1] + f[2] * u[2];
    for (int i = 0; i < 3; i++) f[i] -= along * u[i];
    float n = sqrtf(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
    if (n < 1e-4f) return 0; /* (straight above or below it: as the game does) */
    for (int i = 0; i < 3; i++) f[i] /= n;
    float r[3] = { u[1] * f[2] - u[2] * f[1], u[2] * f[0] - u[0] * f[2], u[0] * f[1] - u[1] * f[0] };
    float c = coss(angle), s = sins(angle);
    for (int i = 0; i < 3; i++) {
        dest[0][i] = c * r[i] + s * u[i];
        dest[1][i] = -s * r[i] + c * u[i];
        dest[2][i] = f[i];
        dest[3][i] = t[i];
    }
    dest[0][3] = dest[1][3] = dest[2][3] = 0;
    dest[3][3] = 1;
    return 1;
}
/* Where you are, in the level (for a Mario to wave at): your head, out of the camera's view space as the game draws
 * it (geo_process_camera's), in MR; else the game camera */
void unity_camera_further(float *pos, const float *focus);
void unity_viewer(Vec3f out) {
    Vec3f eye;
    vec3f_copy(eye, gLakituState.pos);
    unity_camera_further(eye, gLakituState.focus);
    if (!billboard_eye) { vec3f_copy(out, eye); return; }
    Mat4 view;
    mtxf_lookat(view, eye, gLakituState.focus, 0);
    for (int j = 0; j < 3; j++) {
        out[j] = 0;
        for (int i = 0; i < 3; i++) out[j] += (billboard_at[i] - view[3][i]) * view[j][i];
    }
}

/* A sky's tile at a place in its panorama (row * 10 + column, skybox.c's): with the game's data outside it, the
 * tile's path in the resource pack ("textures/skybox_tiles/water.0.rgba16"); identical tiles are stored once */
typedef const u8 *const UnitySkyboxTexture[80];
extern UnitySkyboxTexture *sSkyboxTextures[10];
EXPORT const char *sm64unity_sky_tile(int background, int index) {
    if (background < 0 || background >= 10 || index < 0 || index >= 80) return NULL;
    return (const char *)(*sSkyboxTextures[background])[index];
}
EXPORT int sm64unity_sky(int *color) {
    int background = sky_seen ? sky_background : -1;
    if (color) *color = sky_color;
    sky_seen = 0;
    return background;
}
void unity_apply_options(void) {
    configMasterVolume = gUnityOptions[UNITY_OPT_MASTER_VOLUME];
    configMusicVolume = gUnityOptions[UNITY_OPT_MUSIC_VOLUME];
    configSfxVolume = gUnityOptions[UNITY_OPT_SFX_VOLUME];
    configEnvVolume = gUnityOptions[UNITY_OPT_ENV_VOLUME];
    configHUD = gUnityOptions[UNITY_OPT_HUD] != 0;
    /* The cheats: on the first frame from what Unity kept, then the menu's switches (which toggle Cheats' own
     * bools) back into the option, for Unity to keep */
    static int cheats_loaded;
    bool *cheat = (bool *) &Cheats;
    int cheat_count = sizeof(Cheats) / sizeof(bool);
    if (!cheats_loaded) {
        for (int i = 0; i < cheat_count; i++) cheat[i] = (gUnityOptions[UNITY_OPT_CHEATS] >> i) & 1;
        unsigned int hands = gUnityOptions[UNITY_OPT_HAND_CHEATS] ^ UNITY_HAND_CHEATS_INVERTED;
        for (int i = 0; i < UNITY_HAND_CHEAT_COUNT; i++) gUnityHandCheats[i] = (hands >> i) & 1;
        cheats_loaded = 1;
    }
    unsigned int bits = 0, hand_bits = 0;
    for (int i = 0; i < cheat_count; i++) bits |= (unsigned int) cheat[i] << i;
    for (int i = 0; i < UNITY_HAND_CHEAT_COUNT; i++) hand_bits |= (unsigned int) (gUnityHandCheats[i] != 0) << i;
    gUnityOptions[UNITY_OPT_CHEATS] = bits;
    gUnityOptions[UNITY_OPT_HAND_CHEATS] = hand_bits ^ UNITY_HAND_CHEATS_INVERTED;
}
/* 0: original game, 1: held in game, 2: held in room, 3: released in room. */
static int carry_mode;
static float carry_pos[3];
/* Where he was carried from: a warp to another level or area (exiting a course, a star, a death) brings him back
 * into the game, out of the room and out of the hand */
static s16 carry_level=-1, carry_area=-1;
/* Where he was in the level when first taken out of it: back there if the room has no floor under him (the game
 * would count that as out of bounds and kill him, WARP_OP_DEATH: Bowser's laugh, over and over while he's still in
 * the room after the warp) */
static float carry_from[3];
extern void unity_room_begin(void);
extern void unity_room_end(void);
extern int unity_room_surface_count(void);
extern void unity_skip_interpolation(void);

static int hold_camera;
/* Once the camera has been held (Mario carried, or standing on a hand), it starts again as after a warp: following
 * him from wherever he is now, rather than from where it stopped (camera.c, update_camera) */
static int camera_reset_due;
int unity_camera_reset_due(void) { int due=camera_reset_due; camera_reset_due=0; return due; }
int unity_mario_outside(void) { return carry_mode >= 2; }
int unity_mario_carried(void) { return carry_mode != 0; }
/* In a hand now (not let go of out in the room) */
int unity_mario_held(void) { return carry_mode == 1 || carry_mode == 2; }
/* The camera holds still while Mario is carried, and while the host asks (a hand reaching into the game: the world
 * holds still for it, and billboards face the camera) */
int unity_camera_frozen(void) { return carry_mode != 0 || hold_camera; }
/* hold: 0 let it go, 1 hold it (a hand reaching in: it carries on from there after), 2 hold it and start again after
 * (Mario standing on a hand) */
static int reset_after_hold;
EXPORT void sm64unity_hold_camera(int hold) {
    if (hold==2) reset_after_hold=1;
    if (hold_camera && !hold && reset_after_hold) camera_reset_due=1;
    if (!hold) reset_after_hold=0;
    hold_camera=hold != 0;
}
EXPORT int sm64unity_carry_mode(void) { return carry_mode; }
EXPORT int sm64unity_mario(float *state) {
    if (!gMarioObject || !gMarioState || !gMarioState->action) return 0;
    for (int i=0;i<3;i++) { state[i]=gMarioState->pos[i]; state[i+3]=gMarioState->vel[i]; }
    state[6]=gMarioState->faceAngle[1]; state[7]=gMarioState->health;
    return !(gMarioObject->header.gfx.node.flags & GRAPH_RENDER_INVISIBLE)
        && (gMarioState->action & ACT_GROUP_MASK)!=ACT_GROUP_CUTSCENE
        && gCamera && !gCamera->cutscene ? 2 : 1;
}
/* Is there a floor under this point of the room, as the game's own step (update_mario_geometry_inputs) finds it? */
static int room_floor_under(float x,float y,float z) {
    struct Surface *floor;
    unity_room_begin();
    find_floor(x,y,z,&floor);
    unity_room_end();
    return floor!=NULL;
}
/* Out in the room the stick steers by your head, as in the game it steers by the camera: the game camera's yaw
 * means nothing in the room's coordinates (up on the stick went any way at all, depending on where it had
 * looked). The host gives the way back towards you from where you look, level, in the room (sm64unity_room_facing) */
static int room_facing_on;
static float room_facing[2];
EXPORT void sm64unity_room_facing(int on, float x, float z) {
    room_facing_on = on && isfinite(x) && isfinite(z) && x * x + z * z > 1e-6f;
    if (room_facing_on) { room_facing[0] = x; room_facing[1] = z; }
}
/* The camera's yaw for the stick (mario.c, update_mario_joystick_inputs): towards the camera from Mario */
s16 unity_stick_yaw(s16 camera_yaw) {
    if (carry_mode != 3 || !room_facing_on) return camera_yaw;
    return atan2s(room_facing[1], room_facing[0]);
}
/* Back into the game where he was taken from, falling */
static void return_to_game(void) {
    carry_mode=0;
    unity_skip_interpolation();
    vec3f_copy(gMarioState->pos,carry_from);
    vec3f_copy(gMarioObject->header.gfx.pos,carry_from);
    vec3f_set(gMarioState->vel,0,0,0);
    gMarioState->forwardVel=0;
    set_mario_action(gMarioState,ACT_FREEFALL,0);
}
/* A warp (level_update.c, init_mario_after_warp) puts him at its spawn point, in the game */
extern void unity_room_objects_warped(void);
extern void unity_marios_warped(void);
extern void stage_room_warped(void);
void unity_mario_warped(void) {
    stage_room_warped(); /* (the disc stage out in your room, left: unity_stage.inc.h) */
    unity_room_objects_warped(); /* (and what was out in the room with him, unity_room_objects.inc.h) */
    unity_marios_warped(); /* (the extra Marios gone: unity_marios.inc.h) */
    if (!carry_mode) return;
    carry_mode=0;
    unity_skip_interpolation();
}
EXPORT int sm64unity_carry(int mode, float x,float y,float z,float vx,float vy,float vz) {
    if (!gMarioObject || !gMarioState || !gMarioState->action || mode<0 || mode>3) return 0;
    if (!isfinite(x)||!isfinite(y)||!isfinite(z)||!isfinite(vx)||!isfinite(vy)||!isfinite(vz)) return 0;
    if (mode==3 && (unity_room_surface_count()==0 || !room_floor_under(x,y,z))) return 0;
    int was_held=carry_mode==1 || carry_mode==2;
    if (carry_mode==0 && mode!=0) vec3f_copy(carry_from,gMarioState->pos);
    if ((carry_mode>=2) != (mode>=2)) unity_skip_interpolation(); /* changing worlds: no in-between frame */
    carry_mode=mode;
    carry_level=gCurrLevelNum; carry_area=gCurrAreaIndex;
    vec3f_set(carry_pos,x,y,z);
    vec3f_copy(gMarioState->pos,carry_pos);
    vec3f_copy(gMarioObject->header.gfx.pos,carry_pos);
    if (mode==0 || mode==3) {
        vec3f_set(gMarioState->vel,vx,vy,vz);
        gMarioState->forwardVel=sqrtf(vx*vx+vz*vz);
        if (gMarioState->forwardVel>0.1f)gMarioState->faceAngle[1]=atan2s(vz,vx);
        if (was_held)set_mario_action(gMarioState,ACT_FREEFALL,0);
    }
    return 1;
}

s32 unity_execute_mario_action(struct Object *o) {
    if (carry_mode && (gCurrLevelNum!=carry_level || gCurrAreaIndex!=carry_area)) {
        carry_mode=0;
        unity_skip_interpolation();
    }
    if (carry_mode==1 || carry_mode==2) {
        /* hanging from the hand, as when something grabs him */
        set_mario_animation(gMarioState,MARIO_ANIM_BEING_GRABBED);
        vec3f_copy(gMarioState->pos,carry_pos);
        vec3f_copy(gMarioObject->header.gfx.pos,carry_pos);
        vec3f_set(gMarioState->vel,0,0,0);
        gMarioState->forwardVel=0;
        gMarioState->particleFlags=0;
        return 0;
    }
    if (!unity_mario_outside()) return execute_mario_action(o);
    /* Off the edge of what the room has scanned (or moved there by a hand): no floor, which the game would take
     * for out of bounds and kill him for. Back into the game instead */
    if (!room_floor_under(gMarioState->pos[0],gMarioState->pos[1],gMarioState->pos[2])) {
        return_to_game();
        return execute_mario_action(o);
    }
    unity_room_begin();
    s32 result=execute_mario_action(o);
    unity_room_end();
    return result;
}

EXPORT float sm64unity_room_floor(float x,float y,float z) {
    struct Surface *floor;
    unity_room_begin();
    float height=find_floor(x,y,z,&floor);
    unity_room_end();
    return height;
}

/* In MR the window is a view into the game from across the room: C-down past the game's own zoomed-out step goes
 * further back (up to three more steps, each the camera 40% further from what it looks at; drawing only, so Mario's
 * controls and the camera's collisions are the game's), and C-up comes back through them before zooming in */
extern int unity_is_mr(void);
static int further_steps;
static float further_scale=1.f;
int unity_zoom_further(void) {
    if (!unity_is_mr() || further_steps>=3) return 0;
    further_steps++;
    return 1;
}
int unity_zoom_back(void) {
    if (further_steps<=0) return 0;
    further_steps--;
    return 1;
}
void unity_camera_ease(void) {
    float goal=1.f+0.4f*further_steps;
    further_scale+=(goal-further_scale)*0.2f;
    if (fabsf(goal-further_scale)<0.001f) further_scale=goal;
}
void unity_camera_further(float *pos, const float *focus) {
    if (further_scale==1.f) return;
    for (int i=0;i<3;i++) pos[i]=focus[i]+(pos[i]-focus[i])*further_scale;
}
