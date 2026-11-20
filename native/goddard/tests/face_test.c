// The title screen's face (libgoddard) with your hands as rays (gd_api_set_hand_ray): a pinch takes hold of the
// point of the face you see under it, from wherever your eye is; the point follows the pinch 1:1, towards you too;
// it springs back when you let go; two hands hold two points, and never both lose one. Run by run_goddard_test.sh.
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <ultra64.h>
#include "goddard/gd_types.h"
#include "goddard/gd_math.h"
#include "goddard/objects.h"
#include "gd_api.h"
#undef printf

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static int njoints;
static struct ObjJoint *joints[16];
static void find_joints(void) {
    njoints = 0;
    for (struct GdObj *o = gGdObjectList; o; o = o->next)
        if (o->type == OBJ_TYPE_JOINTS && (o->drawFlags & OBJ_IS_GRABBABLE) && njoints < 16) joints[njoints++] = (struct ObjJoint *) o;
}
GD_API void gd_api_joint_eye(const void *joint, float out[3], float rest[3]);
// Where a joint is drawn (eye space, as gd_api_vertices); the head moves on its own, so this is aimed at each time
static void eye_of(struct ObjJoint *j, float out[3]) { float r[3]; gd_api_joint_eye(j, out, r); }
static struct ObjJoint *picked(void) {
    extern struct GdObj *gMarioFacePicked2;
    for (int i = 0; i < njoints; i++)
        if ((joints[i]->header.drawFlags & OBJ_PICKED) && (struct GdObj *) joints[i] != gMarioFacePicked2) return joints[i];
    return NULL;
}
static struct ObjJoint *picked2(void) {
    extern struct GdObj *gMarioFacePicked2;
    return (struct ObjJoint *) gMarioFacePicked2;
}
static int index_of(struct ObjJoint *p) {
    for (int i = 0; i < njoints; i++) if (joints[i] == p) return i;
    return -1;
}
static float offset(struct ObjJoint *j) {
    float x = j->mat128[3][0] - j->initPos.x, y = j->mat128[3][1] - j->initPos.y, z = j->mat128[3][2] - j->initPos.z;
    return sqrtf(x * x + y * y + z * z);
}
static float dist(const float a[3], const float b[3]) {
    return sqrtf((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
}

// A hand: eye, and the pinch `along` of the way from the eye to `at`, plus `move`
typedef struct { float eye[3], at[3], move[3], along; int pinch; } Hand;
static void place(int i, const Hand *h) {
    float f[3], d[3];
    for (int k = 0; k < 3; k++) {
        d[k] = h->at[k] - h->eye[k];
        f[k] = h->eye[k] + d[k] * h->along + h->move[k];
    }
    gd_api_set_hand_ray(i, 1, h->eye, d, f);
}
static int ticks(int n, const Hand *one, const Hand *two) {
    int sfx = 0;
    for (int f = 0; f < n; f++) {
        if (one) place(0, one); else gd_api_set_hand_ray(0, 0, NULL, NULL, NULL);
        if (two) place(1, two); else gd_api_set_hand_ray(1, 0, NULL, NULL, NULL);
        gd_api_set_hand2(two != NULL, 160, 120, two && two->pinch, 0, 0, 0);
        sfx |= gd_api_tick(one != NULL, 160, 120, one && one->pinch ? 0x8000 : 0, 0, 0, 0);
    }
    return sfx;
}

static void let_go(void) {
    ticks(60, NULL, NULL);
    for (int i = 0; i < njoints; i++) CHECK(offset(joints[i]) < 2, "joint %d still %.1f out after letting go", i, offset(joints[i]));
}

int main(void) {
    gd_api_init();
    ticks(400, NULL, NULL);  // (the intro: the head zooms in)
    find_joints();
    CHECK(njoints == 7, "%d grabbable joints, not 7", njoints);
    float rest[16][3];
    for (int i = 0; i < njoints; i++) eye_of(joints[i], rest[i]);

    // The joints are on the face that's drawn: each near a vertex of the face
    int vcount;
    const GdVertex *v = gd_api_vertices(&vcount);
    for (int i = 0; i < njoints; i++) {
        float best = 1e9f;
        for (int n = 0; n < vcount; n++) { float d = dist(v[n].pos, rest[i]); if (d < best) best = d; }
        CHECK(best < 150, "joint %d is %.0f from the drawn face (eye space mismatch?)", i, best);
    }

    // 1. Each point, pinched where you see it, from Goddard's camera, from off to the side and above, at arm's length
    //    and right at the face, and a little off the point (a quarter of the way to its nearest neighbour)
    // (aimed where each point is just before the pinch: the head moves on its own)
    const float eyes[][3] = { { 0, 0, 0 }, { 600, 300, -200 }, { -700, -250, -100 }, { 0, 500, -400 } };
    const float alongs[] = { 0.55f, 0.97f };
    int picks = 0, right = 0;
    for (int e = 0; e < 4; e++)
        for (int a = 0; a < 2; a++)
            for (int i = 0; i < njoints; i++) {
                for (int n = 0; n < njoints; n++) eye_of(joints[n], rest[n]);
                // (nearest neighbour as seen from this eye)
                float off[3] = { 0, 0, 0 }, bestAngle = 1e9f;
                for (int n = 0; n < njoints; n++) {
                    if (n == i) continue;
                    float u[3], w[3], lu = 0, lw = 0, dot = 0;
                    for (int k = 0; k < 3; k++) { u[k] = rest[i][k] - eyes[e][k]; w[k] = rest[n][k] - eyes[e][k]; }
                    for (int k = 0; k < 3; k++) { lu += u[k] * u[k]; lw += w[k] * w[k]; dot += u[k] * w[k]; }
                    float ang = acosf(fminf(1, dot / sqrtf(lu * lw)));
                    if (ang < bestAngle) {
                        bestAngle = ang;
                        // a quarter of the way towards it, at this point's distance
                        for (int k = 0; k < 3; k++) off[k] = (eyes[e][k] + w[k] * sqrtf(lu / lw) - rest[i][k]) * 0.25f;
                    }
                }
                Hand h = { { eyes[e][0], eyes[e][1], eyes[e][2] }, { rest[i][0] + off[0], rest[i][1] + off[1], rest[i][2] + off[2] },
                           { 0, 0, 0 }, alongs[a], 0 };
                h.pinch = 1;
                ticks(3, &h, NULL);
                picks++;
                struct ObjJoint *p = picked();
                if (p == joints[i]) right++;
                else CHECK(0, "eye %d along %.2f: pinched joint %d, took hold of %d", e, alongs[a], i,
                           index_of(p));
                CHECK(gd_api_holding(), "eye %d: pinching joint %d doesn't hold", e, i);
                h.pinch = 0;
                ticks(1, &h, NULL);
                ticks(60, NULL, NULL);
            }
    printf("picks: %d of %d took hold of the point pinched\n", right, picks);

    // Thin air (well off the head) takes hold of nothing
    {
        Hand h = { { 0, 0, 0 }, { 1500, 900, -1700 }, { 0, 0, 0 }, 0.6f, 1 };
        ticks(6, &h, NULL);
        CHECK(picked() == NULL && !gd_api_holding(), "a pinch in thin air took hold");
        ticks(60, NULL, NULL);
    }

    // 2. The point follows the pinch 1:1: sideways, up, and towards you (out of the window)
    const float moves[][3] = { { 150, 0, 0 }, { 0, 120, 0 }, { 0, 0, 250 }, { -100, -60, 180 } };
    for (int m = 0; m < 4; m++)
        for (int i = 0; i < njoints; i++) {
            eye_of(joints[i], rest[i]);
            Hand h = { { 300, 100, -300 }, { rest[i][0], rest[i][1], rest[i][2] }, { 0, 0, 0 }, 0.8f, 1 };
            ticks(2, &h, NULL);
            CHECK(picked() == joints[i], "drag %d: not holding joint %d", m, i);
            eye_of(joints[i], rest[i]);  // (where it was when it took hold)
            for (int f = 1; f <= 15; f++) {  // (moved over half a second)
                for (int k = 0; k < 3; k++) h.move[k] = moves[m][k] * f / 15;
                ticks(1, &h, NULL);
            }
            ticks(45, &h, NULL);
            float now[3], want[3];
            eye_of(joints[i], now);
            for (int k = 0; k < 3; k++) want[k] = rest[i][k] + moves[m][k];
            float len = sqrtf(moves[m][0] * moves[m][0] + moves[m][1] * moves[m][1] + moves[m][2] * moves[m][2]);
            CHECK(dist(now, want) < len * 0.1f, "drag %d joint %d: (%.0f,%.0f,%.0f) for (%.0f,%.0f,%.0f), %.0f off", m, i,
                  now[0] - rest[i][0], now[1] - rest[i][1], now[2] - rest[i][2], moves[m][0], moves[m][1], moves[m][2],
                  dist(now, want));
            h.pinch = 0;
            int sfx = ticks(1, &h, NULL) | ticks(2, NULL, NULL);
            CHECK(sfx & 0x20, "drag %d joint %d: no let-go sound", m, i);
            let_go();
        }

    // 3. Two hands, two points, pulled apart
    {
        for (int n = 0; n < njoints; n++) eye_of(joints[n], rest[n]);
        int a = 0, b = 1;  // (whichever two)
        Hand h1 = { { 0, 0, 0 }, { rest[a][0], rest[a][1], rest[a][2] }, { 0, 0, 0 }, 0.7f, 1 };
        Hand h2 = { { 0, 0, 0 }, { rest[b][0], rest[b][1], rest[b][2] }, { 0, 0, 0 }, 0.7f, 1 };
        ticks(2, &h1, &h2);
        CHECK(picked() == joints[a] && picked2() == joints[b], "two hands didn't take hold of their two points");
        eye_of(joints[a], rest[a]); eye_of(joints[b], rest[b]);
        h1.move[0] = -120; h2.move[0] = 120;
        ticks(60, &h1, &h2);
        float pa[3], pb[3];
        eye_of(joints[a], pa); eye_of(joints[b], pb);
        CHECK(fabsf(pa[0] - rest[a][0] + 120) < 15 && fabsf(pb[0] - rest[b][0] - 120) < 15,
              "two hands: moved %.0f and %.0f for -120 and 120", pa[0] - rest[a][0], pb[0] - rest[b][0]);
        h1.pinch = h2.pinch = 0;
        ticks(2, &h1, &h2);
        let_go();
    }

    // 4. Both hands on one point: the second to pinch doesn't take it from the first, who keeps pulling it
    for (int first = 0; first < 2; first++) {
        int i = 3;
        eye_of(joints[i], rest[i]);
        Hand on = { { 0, 0, 0 }, { rest[i][0], rest[i][1], rest[i][2] }, { 0, 0, 0 }, 0.7f, 1 };
        Hand other = on;
        other.pinch = 0;
        if (first == 0) ticks(2, &on, &other); else ticks(2, &other, &on);
        CHECK(first == 0 ? picked() == joints[i] : picked2() == joints[i], "hand %d didn't take hold of the nose", first);
        eye_of(joints[i], rest[i]);
        on.move[1] = 100;
        other.pinch = 1;
        if (first == 0) ticks(60, &on, &other); else ticks(60, &other, &on);
        float p[3];
        eye_of(joints[i], p);
        CHECK(fabsf(p[1] - rest[i][1] - 100) < 15, "hand %d holding, the other pinching the same point: it moved %.0f of 100",
              first, p[1] - rest[i][1]);
        on.pinch = other.pinch = 0;
        ticks(2, &on, &other);
        let_go();
    }

    // 5. Goddard's own cursor (no rays: the console's way) still takes hold and stretches
    {
        eye_of(joints[3], rest[3]);
        float m[16];
        gd_api_projection(m);
        float *nose = rest[3];
        float c[4];
        for (int k = 0; k < 4; k++) c[k] = nose[0] * m[k] + nose[1] * m[4 + k] + nose[2] * m[8 + k] + m[12 + k];
        float x = 160 + c[0] / c[3] * 160, y = 120 - c[1] / c[3] * 120;
        for (int f = 0; f < 40; f++) {
            gd_api_set_hand_ray(0, 0, NULL, NULL, NULL);
            gd_api_tick(1, x + (f > 5 ? 30 : 0), y, f > 1 ? 0x8000 : 0, 0, 0, 0);
        }
        CHECK(gd_api_holding() && offset(joints[3]) > 50, "the 2D cursor doesn't stretch the nose");
        for (int f = 0; f < 60; f++) gd_api_tick(1, x, y, 0, 0, 0, 0);
    }

    printf(failures ? "face_test: %d FAILED\n" : "face_test: all passed\n", failures);
    return failures != 0;
}
