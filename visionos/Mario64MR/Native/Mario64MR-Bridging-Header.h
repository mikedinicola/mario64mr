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

const int16_t *sm64unity_audio(int *count);
void sm64unity_audio_buffered(int frames);

void sm64unity_cursor(int enabled, float x, float y);
void sm64unity_hand_depth(float depth);
void sm64unity_billboards(int on, float x, float y, float z, float ux, float uy, float uz);
void sm64unity_hold_camera(int hold);

int sm64unity_room_mesh(const int16_t *triangles, int count);
int sm64unity_room_hands(const int16_t *triangles, int count);
int sm64unity_game_hands(const int16_t *triangles, int count);
float sm64unity_room_floor(float x, float y, float z);
int sm64unity_carry(int mode, float x, float y, float z, float vx, float vy, float vz);
int sm64unity_carry_mode(void);
int sm64unity_mario(float *state);
int sm64unity_mario_on_hand(void);
void sm64unity_displace(float dx, float dy, float dz);

unsigned int *sm64unity_options(void);
int sm64unity_option_count(void);

// ---------------------------------------------------------------- Goddard (native/goddard/shim/gd_api.h)
int32_t gd_api_texture_slot_count(void);

// ---------------------------------------------------------------- LibSM64 (libsm64.h, upstream)
#define SM64_TEXTURE_WIDTH 704  // (64 * 11)
#define SM64_TEXTURE_HEIGHT 64
void sm64_global_init(const uint8_t *rom, uint8_t *outTexture);
