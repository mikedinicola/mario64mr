/* A picture of the frame the game last drew, for a test to look at: the bridge's triangles (unity_bridge.c, as the
 * host gets them) drawn in software, near enough to the host's shader (its colour combiner, textures, depth, alpha) to
 * see what's where and how it stands. Written as a PNG.
 *   snapshot("out.png", 640, 360);
 * Or the level (no sky, no HUD) from a camera of the test's own, looking from eye at target (game units):
 *   snapshot_from("out.png", 640, 360, eye, target);
 * Include it in a test (after the game's headers); it needs nothing else. */
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
#include "pc/gfx/gfx_cc.h"

struct SnapshotBatch {
    uint32_t shader_id;
    int first_float, float_count, triangle_count;
    uint32_t texture0, texture1;
    int depth_test, depth_write, decal, blend;
    int viewport[4], scissor[4];
    int filter0, wraps0, wrapt0, filter1, wraps1, wrapt1;
};
const struct SnapshotBatch *sm64unity_batches(int *count);
const float *sm64unity_vertices(int *count);
const float *sm64unity_camera(void);
const float *sm64unity_projections(void);
const uint8_t *sm64unity_texture(int id, int *w, int *h, int *version);
int sm64unity_batch_size(void);
int sm64unity_interpolates(void);

static void snapshot_texel(uint32_t id, int wraps, int wrapt, float u, float v, float out[4]) {
    int w, h, version;
    const uint8_t *p = id ? sm64unity_texture((int) id, &w, &h, &version) : NULL;
    if (!p || w <= 0 || h <= 0) { out[0] = out[1] = out[2] = out[3] = 1.f; return; }
    int x = (int) floorf(u * w), y = (int) floorf(v * h);
    /* (G_TX_CLAMP is 2, mirror 1: near enough as wrapping) */
    if (wraps & 2) x = x < 0 ? 0 : x >= w ? w - 1 : x; else x = ((x % w) + w) % w;
    if (wrapt & 2) y = y < 0 ? 0 : y >= h ? h - 1 : y; else y = ((y % h) + h) % h;
    const uint8_t *t = p + 4 * (y * w + x);
    for (int i = 0; i < 4; i++) out[i] = t[i] / 255.f;
}

/* The combiner's (a - b) * c + d, of one channel (k: 0-2 colour, 3 alpha) */
static float snapshot_source(int which, const float *inputs[4], const float t0[4], const float t1[4], int k) {
    switch (which) {
        case SHADER_INPUT_1: case SHADER_INPUT_2: case SHADER_INPUT_3: case SHADER_INPUT_4:
            return inputs[which - SHADER_INPUT_1][k];
        case SHADER_TEXEL0: return t0[k];
        case SHADER_TEXEL0A: return t0[3];
        case SHADER_TEXEL1: return t1[k];
        default: return 0.f;
    }
}
static float snapshot_combine(const struct CCFeatures *f, int alpha, const float *inputs[4], const float t0[4],
                              const float t1[4], int k) {
    const uint8_t *c = f->c[alpha];
    float a = snapshot_source(c[0], inputs, t0, t1, k), b = snapshot_source(c[1], inputs, t0, t1, k);
    float m = snapshot_source(c[2], inputs, t0, t1, k), d = snapshot_source(c[3], inputs, t0, t1, k);
    if (f->do_single[alpha]) return d;
    if (f->do_multiply[alpha]) return a * m;
    if (f->do_mix[alpha]) return (a - b) * m + b;
    return (a - b) * m + d;
}

static void snapshot_png(const char *path, const uint8_t *rgb, int w, int h) {
    size_t raw_size = (size_t) (3 * w + 1) * h;
    uint8_t *raw = malloc(raw_size);
    for (int y = 0; y < h; y++) { raw[y * (3 * w + 1)] = 0; memcpy(raw + y * (3 * w + 1) + 1, rgb + 3 * w * y, 3 * w); }
    uLongf packed_size = compressBound(raw_size);
    uint8_t *packed = malloc(packed_size);
    compress(packed, &packed_size, raw, raw_size);
    FILE *f = fopen(path, "wb");
    if (!f) { free(raw); free(packed); return; }
    #define SNAPSHOT_U32(x) do { uint8_t b_[4] = { (x) >> 24, (x) >> 16, (x) >> 8, (x) }; fwrite(b_, 1, 4, f); } while (0)
    #define SNAPSHOT_CHUNK(kind, data, n) do { \
        SNAPSHOT_U32((uint32_t) (n)); uint8_t k_[4]; memcpy(k_, kind, 4); fwrite(k_, 1, 4, f); fwrite(data, 1, n, f); \
        uLong crc_ = crc32(crc32(0, k_, 4), (const Bytef *) (data), (uInt) (n)); SNAPSHOT_U32((uint32_t) crc_); } while (0)
    fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
    uint8_t header[13] = { w >> 24, w >> 16, w >> 8, w, h >> 24, h >> 16, h >> 8, h, 8, 2, 0, 0, 0 };
    SNAPSHOT_CHUNK("IHDR", header, 13);
    SNAPSHOT_CHUNK("IDAT", packed, packed_size);
    SNAPSHOT_CHUNK("IEND", "", 0);
    #undef SNAPSHOT_CHUNK
    #undef SNAPSHOT_U32
    fclose(f);
    free(raw); free(packed);
}

/* 4x4 matrices as the game's (row vectors: v' = v * M) */
static void snapshot_mul(const float v[4], const float m[16], float out[4]) {
    for (int j = 0; j < 4; j++) out[j] = v[0] * m[j] + v[1] * m[4 + j] + v[2] * m[8 + j] + v[3] * m[12 + j];
}
static void snapshot_times(const float a[16], const float b[16], float out[16]) {
    for (int i = 0; i < 4; i++) snapshot_mul(a + 4 * i, b, out + 4 * i);
}
static int snapshot_invert(const float m[16], float out[16]) {
    float a[4][8];
    for (int i = 0; i < 4; i++) for (int j = 0; j < 8; j++) a[i][j] = j < 4 ? m[4 * i + j] : (j - 4 == i);
    for (int c = 0; c < 4; c++) {
        int p = c;
        for (int r = c + 1; r < 4; r++) if (fabsf(a[r][c]) > fabsf(a[p][c])) p = r;
        if (fabsf(a[p][c]) < 1e-12f) return 0;
        for (int j = 0; j < 8; j++) { float t = a[c][j]; a[c][j] = a[p][j]; a[p][j] = t; }
        float d = a[c][c];
        for (int j = 0; j < 8; j++) a[c][j] /= d;
        for (int r = 0; r < 4; r++) if (r != c) { float k = a[r][c]; for (int j = 0; j < 8; j++) a[r][j] -= k * a[c][j]; }
    }
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) out[4 * i + j] = a[i][4 + j];
    return 1;
}
/* A camera at eye looking at target, and a 45 degree view: world to clip */
static void snapshot_look(const float eye[3], const float target[3], float aspect, float out[16]) {
    float f[3] = { target[0] - eye[0], target[1] - eye[1], target[2] - eye[2] };
    float n = sqrtf(f[0] * f[0] + f[1] * f[1] + f[2] * f[2]);
    for (int i = 0; i < 3; i++) f[i] /= n;
    float r[3] = { -f[2], 0, f[0] }; /* (f x up) */
    n = sqrtf(r[0] * r[0] + r[2] * r[2]);
    r[0] /= n; r[2] /= n;
    float u[3] = { r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0] };
    float view[16] = { r[0], u[0], -f[0], 0, r[1], u[1], -f[1], 0, r[2], u[2], -f[2], 0, 0, 0, 0, 1 };
    for (int j = 0; j < 3; j++) view[12 + j] = -(eye[0] * view[j] + eye[1] * view[4 + j] + eye[2] * view[8 + j]);
    float near = 20.f, far = 20000.f, t = 1.f / tanf(45.f * (float) M_PI / 360.f);
    float projection[16] = { t / aspect, 0, 0, 0, 0, t, 0, 0, 0, 0, (far + near) / (near - far), -1,
                             0, 0, 2 * far * near / (near - far), 0 };
    snapshot_times(view, projection, out);
}

static void snapshot_draw(const char *path, int width, int height, const float *eye, const float *target);
static void snapshot(const char *path, int width, int height) { snapshot_draw(path, width, height, NULL, NULL); }
static void snapshot_from(const char *path, int width, int height, const float eye[3], const float target[3]) {
    snapshot_draw(path, width, height, eye, target);
}

#define SNAPSHOT_MAX_STRIDE 40
static void snapshot_draw(const char *path, int width, int height, const float *eye, const float *target) {
    int batch_count, float_count;
    const struct SnapshotBatch *batches = sm64unity_batches(&batch_count);
    const float *floats = sm64unity_vertices(&float_count);
    if (sm64unity_batch_size() != (int) sizeof(struct SnapshotBatch)) { printf("  (snapshot: the batch changed)\n"); return; }
    float window_w = sm64unity_interpolates() ? 1280.f : 320.f, window_h = sm64unity_interpolates() ? 720.f : 240.f;
    float sx = width / window_w, sy = height / window_h;
    const float *projections = sm64unity_projections(), *camera = sm64unity_camera();
    float mine[16], world_from_view[16];
    if (eye) {
        snapshot_look(eye, target, (float) width / height, mine);
        snapshot_invert(camera, world_from_view);
    }
    uint8_t *rgb = calloc((size_t) width * height, 3);
    if (eye) for (int i = 0; i < width * height; i++) { rgb[3 * i] = 0x60; rgb[3 * i + 1] = 0x90; rgb[3 * i + 2] = 0xC0; }
    float *depth = malloc(sizeof(float) * width * height);
    for (int i = 0; i < width * height; i++) depth[i] = 2.f;
    for (int b = 0; b < batch_count; b++) {
        const struct SnapshotBatch *batch = &batches[b];
        if (batch->triangle_count <= 0) continue;
        struct CCFeatures f;
        gfx_cc_get_features(batch->shader_id, &f);
        int stride = batch->float_count / (batch->triangle_count * 3);
        int textured = f.used_textures[0] || f.used_textures[1];
        int input_size = f.opt_alpha ? 4 : 3;
        int vx = batch->viewport[0], vy = batch->viewport[1], vw = batch->viewport[2], vh = batch->viewport[3];
        if (stride > SNAPSHOT_MAX_STRIDE) continue;
        /* From a camera of our own: only the level's (perspective, not the HUD's), taken back into the world through
         * the game's projection and camera, and on through ours, filling the picture */
        const float *projection = projections + 16 * b;
        int perspective = projection[11] != 0.f; /* (guPerspective's -1 there, guOrtho's 0) */
        float reproject[16];
        if (eye) {
            if (!perspective) continue;
            float view_from_clip[16], world_from_clip[16];
            if (!snapshot_invert(projection, view_from_clip)) continue;
            snapshot_times(view_from_clip, world_from_view, world_from_clip);
            snapshot_times(world_from_clip, mine, reproject);
            vx = vy = 0; vw = (int) window_w; vh = (int) window_h;
        }
        for (int t = 0; t < batch->triangle_count; t++) {
            /* Its corners, clipped to what's in front of the camera (w > near): up to four, a fan */
            float corner[3][SNAPSHOT_MAX_STRIDE], poly[4][SNAPSHOT_MAX_STRIDE];
            for (int i = 0; i < 3; i++) {
                memcpy(corner[i], floats + batch->first_float + (t * 3 + i) * stride, sizeof(float) * stride);
                if (eye) { float out[4]; snapshot_mul(corner[i], reproject, out); memcpy(corner[i], out, sizeof(out)); }
            }
            int count = 0;
            const float near_w = 1e-2f;
            for (int i = 0; i < 3; i++) {
                const float *p = corner[i], *q = corner[(i + 1) % 3];
                int pin = p[3] > near_w, qin = q[3] > near_w;
                if (pin) memcpy(poly[count++], p, sizeof(float) * stride);
                if (pin != qin && count < 4) {
                    float k = (near_w - p[3]) / (q[3] - p[3]);
                    for (int j = 0; j < stride; j++) poly[count][j] = p[j] + (q[j] - p[j]) * k;
                    count++;
                }
            }
            for (int fan = 1; fan + 1 < count; fan++) {
            const float *v[3] = { poly[0], poly[fan], poly[fan + 1] };
            float px[3], py[3], pz[3], iw[3];
            for (int i = 0; i < 3; i++) {
                iw[i] = 1.f / v[i][3];
                px[i] = (vx + (v[i][0] * iw[i] + 1.f) / 2.f * vw) * sx;
                py[i] = (window_h - (vy + (v[i][1] * iw[i] + 1.f) / 2.f * vh)) * sy;
                pz[i] = v[i][2] * iw[i];
            }
            float area = (px[1] - px[0]) * (py[2] - py[0]) - (px[2] - px[0]) * (py[1] - py[0]);
            if (fabsf(area) < 1e-6f) continue;
            int x0 = (int) floorf(fminf(px[0], fminf(px[1], px[2]))), x1 = (int) ceilf(fmaxf(px[0], fmaxf(px[1], px[2])));
            int y0 = (int) floorf(fminf(py[0], fminf(py[1], py[2]))), y1 = (int) ceilf(fmaxf(py[0], fmaxf(py[1], py[2])));
            if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0; if (x1 > width - 1) x1 = width - 1; if (y1 > height - 1) y1 = height - 1;
            for (int y = y0; y <= y1; y++)
                for (int x = x0; x <= x1; x++) {
                    float cx = x + 0.5f, cy = y + 0.5f;
                    float w0 = ((px[1] - cx) * (py[2] - cy) - (px[2] - cx) * (py[1] - cy)) / area;
                    float w1 = ((px[2] - cx) * (py[0] - cy) - (px[0] - cx) * (py[2] - cy)) / area;
                    float w2 = 1.f - w0 - w1;
                    if (w0 < 0 || w1 < 0 || w2 < 0) continue;
                    float z = w0 * pz[0] + w1 * pz[1] + w2 * pz[2];
                    float *d = &depth[y * width + x];
                    if (batch->depth_test && z > *d + (batch->decal ? 1e-3f : 0.f)) continue;
                    /* Perspective-correct: each attribute over w, then back */
                    float p0 = w0 * iw[0], p1 = w1 * iw[1], p2 = w2 * iw[2], sum = p0 + p1 + p2;
                    p0 /= sum; p1 /= sum; p2 /= sum;
                    float attr[32];
                    for (int k = 4; k < stride && k < 36; k++) attr[k - 4] = p0 * v[0][k] + p1 * v[1][k] + p2 * v[2][k];
                    int at = 0;
                    float t0[4] = { 1, 1, 1, 1 }, t1[4] = { 1, 1, 1, 1 };
                    if (textured) {
                        if (f.used_textures[0]) snapshot_texel(batch->texture0, batch->wraps0, batch->wrapt0, attr[0], attr[1], t0);
                        if (f.used_textures[1]) snapshot_texel(batch->texture1, batch->wraps1, batch->wrapt1, attr[0], attr[1], t1);
                        at += 2;
                    }
                    float fog[4] = { 0, 0, 0, 0 };
                    if (f.opt_fog) { memcpy(fog, attr + at, sizeof(fog)); at += 4; }
                    float inputs_storage[4][4] = { { 1, 1, 1, 1 }, { 1, 1, 1, 1 }, { 1, 1, 1, 1 }, { 1, 1, 1, 1 } };
                    const float *inputs[4];
                    for (int i = 0; i < 4; i++) {
                        if (i < f.num_inputs) for (int k = 0; k < input_size; k++) inputs_storage[i][k] = attr[at + i * input_size + k];
                        inputs[i] = inputs_storage[i];
                    }
                    float c[4];
                    for (int k = 0; k < 3; k++) c[k] = snapshot_combine(&f, 0, inputs, t0, t1, k);
                    c[3] = f.opt_alpha ? snapshot_combine(&f, f.color_alpha_same ? 0 : 1, inputs, t0, t1, 3) : 1.f;
                    if (f.opt_texture_edge && c[3] < 0.3f) continue;
                    if (f.opt_fog) for (int k = 0; k < 3; k++) c[k] = c[k] + (fog[k] - c[k]) * fog[3];
                    float alpha = (batch->blend && f.opt_alpha) ? c[3] : 1.f;
                    if (alpha <= 0.01f) continue;
                    uint8_t *o = &rgb[3 * (y * width + x)];
                    for (int k = 0; k < 3; k++) {
                        float value = fminf(1.f, fmaxf(0.f, c[k]));
                        o[k] = (uint8_t) (o[k] + (value * 255.f - o[k]) * alpha);
                    }
                    if (batch->depth_write && alpha > 0.5f) *d = z;
                }
            }
        }
    }
    snapshot_png(path, rgb, width, height);
    free(rgb); free(depth);
}
