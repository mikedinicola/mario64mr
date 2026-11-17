// The three game libraries' C interfaces, as the Swift host calls them. The libraries are built from your ROM by
// install_mario64mr.py --visionos (visionos/Build/Frameworks) and carry no headers of their own: these declarations
// are the contract, checked against the sources in native/ (and, for the batch struct, sm64unity_batch_size()).
#include <stdint.h>

// ---------------------------------------------------------------- SM64Game (native/fullgame, unity_bridge.c)
// One draw call of the game's frame, as the bridge records it (struct UnityBatch in unity_bridge.c)
typedef struct {
    uint32_t shader_id;
    int32_t first_float, float_count, triangle_count;
    uint32_t texture0, texture1;
    int32_t depth_test, depth_write, decal, blend;
    int32_t viewport[4], scissor[4];
    int32_t filter0, wraps0, wrapt0, filter1, wraps1, wrapt1;
} SM64UnityBatch;

int sm64unity_init(const char *save_path);
int sm64unity_tick(uint16_t buttons, int8_t stick_x, int8_t stick_y);
int sm64unity_interpolates(void);
int sm64unity_render_current(void);
int sm64unity_error(void);
int sm64unity_stage(void);
int sm64unity_batch_size(void);

const SM64UnityBatch *sm64unity_batches(int *count);
const float *sm64unity_vertices(int *count);
const float *sm64unity_projections(void);
const int *sm64unity_tags(void);
const float *sm64unity_camera(void);
const uint8_t *sm64unity_texture(int id, int *w, int *h, int *version);
int sm64unity_sky(int *color);
const char *sm64unity_sky_tile(int background, int index);
void sm64unity_mr_geometry(int enabled);
void sm64unity_draw_far(int enabled);

const int16_t *sm64unity_audio(int *count);
void sm64unity_audio_buffered(int frames);

void sm64unity_cursor(int enabled, float x, float y);
void sm64unity_hand_depth(float depth);
void sm64unity_billboards(int on, float x, float y, float z, float ux, float uy, float uz);
void sm64unity_hold_camera(int hold);

int sm64unity_room_mesh(const int16_t *triangles, int count);
int sm64unity_room_hands(const int16_t *triangles, int count);
int sm64unity_game_hands(const int16_t *triangles, int count);
int sm64unity_game_hand_points(const float *points, int count, float radius);  // (unity_hands.inc.h: joints that touch)
int sm64unity_object_grab(float x, float y, float z, float reach);  // (unity_hands.inc.h: pinch to pick up)
int sm64unity_object_hold(float x, float y, float z);
void sm64unity_object_release(float vx, float vy, float vz);
// (unity_room_objects.inc.h: what a pinch picked up, carried out into the room and living there; room game units)
int sm64unity_object_hold_room(float x, float y, float z);
int sm64unity_object_release_room(float vx, float vy, float vz);
int sm64unity_object_grab_room(float x, float y, float z, float reach);
int sm64unity_room_objects(float *out, int max);
int sm64unity_room_object_return(int slot, float x, float y, float z, float vx, float vy, float vz);
void sm64unity_room_objects_return(void);
// (unity_spawn.inc.h: what's taken out of the treasure chest, by SpawnKind)
unsigned int sm64unity_spawn_available(void);
int sm64unity_spawn_held(int kind, int in_room, float x, float y, float z);
int sm64unity_spawn_near_mario(int kind);
// (unity_stage.inc.h: the disc stage's tilt, from the controller's lean, as the stick is; is it on (D-pad up))
void sm64unity_stage_tilt(float forward, float right);
int sm64unity_stage_tilting(void);
float sm64unity_room_floor(float x, float y, float z);
int sm64unity_carry(int mode, float x, float y, float z, float vx, float vy, float vz);
int sm64unity_carry_mode(void);
void sm64unity_room_facing(int on, float x, float z);
int sm64unity_mario(float *state);
int sm64unity_mario_on_hand(void);
void sm64unity_displace(float dx, float dy, float dz);

unsigned int *sm64unity_options(void);
int sm64unity_option_count(void);

// ---------------------------------------------------------------- Goddard (native/goddard/shim/gd_api.h)
typedef struct {
    float pos[3];
    float uv[2];
    uint8_t color[4];
} GdVertex;
typedef struct {
    int32_t firstVertex;
    int32_t vertexCount;
    int32_t texture;
    uint32_t flags;  // GD_BATCH_*: 1 screen, 2 blend, 4 cutout, 8 z test, 16 z write, 32 decal, 64/128 cull, 256 textured
    uint8_t colorCombine[4];
    uint8_t alphaCombine[4];
    uint8_t prim[4];
    uint8_t env[4];
    uint8_t clampS, clampT, mirrorS, mirrorT;
} GdBatch;
int32_t gd_api_init(void);
int32_t gd_api_tick(int32_t setCursor, float cursorX, float cursorY, uint16_t buttons, int8_t stickX, int8_t stickY, int8_t stickZ);
const GdVertex *gd_api_vertices(int32_t *count);
const GdBatch *gd_api_batches(int32_t *count);
void gd_api_projection(float out[16]);
void gd_api_cursor(float *x, float *y);
int32_t gd_api_holding(void);
void gd_api_set_drag_z(int32_t hand, float value);
void gd_api_set_hand2(int32_t setCursor, float cursorX, float cursorY, int32_t a, int8_t stickX, int8_t stickY, int8_t stickZ);
int32_t gd_api_holding2(void);
void gd_api_cursor2(float *x, float *y);
int32_t gd_api_set_texture(const char *name, const uint8_t *data, int32_t size);
int32_t gd_api_texture_slot_count(void);
const char *gd_api_texture_slot(int32_t index, int32_t *width, int32_t *height);
int32_t gd_api_texture_count(void);
void gd_api_texture_size(int32_t index, int32_t *width, int32_t *height);
void gd_api_texture_rgba(int32_t index, uint8_t *out);

// ---------------------------------------------------------------- LibSM64 (libsm64.h, upstream)
#define SM64_TEXTURE_WIDTH 704  // (64 * 11)
#define SM64_TEXTURE_HEIGHT 64
void sm64_global_init(const uint8_t *rom, uint8_t *outTexture);
void sm64_audio_init(const uint8_t *rom);
uint32_t sm64_audio_tick(uint32_t numQueuedSamples, uint32_t numDesiredSamples, int16_t *audio_buffer);
void sm64_play_sound_global(int32_t soundBits);
