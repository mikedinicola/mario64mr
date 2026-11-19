/* The disc stage (Castle Grounds' area 2, through the pipe by where Mario starts): its boxes, and its want of any
 * ground of its own. Mario 64 MR's own geometry, nothing of the ROM's. Included in levels/castle_grounds/leveldata.c by
 * patch_sm64ex.py.
 *
 * The disc is an object (bhvStageDisc: it tilts, and changes shape), its mesh and collision made as the game runs
 * (unity_stage.inc.h, geo_stage_disc); the area's own ground is none. Nothing is under it, so Mario can't walk off
 * its edge (out of bounds). */

const Collision stage_disc_no_collision[] = {
    COL_INIT(),
    COL_VERTEX_INIT(0),
    COL_TRI_STOP(),
    COL_END(),
};

/* A box: a cube 2 * STAGE_BOX_HALF across standing on its origin, its faces lit from above, in the colour the object
 * gives it (the environment colour: geo_stage_box) */
#define STAGE_BOX_HALF 55 /* (laid out touching: unity_stage.inc.h's STAGE_MOSAIC_SPACING) */
#define STAGE_BOX_FACE(x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3, shade) \
    {{{ x0, y0, z0 }, 0, { 0, 0 }, { shade, shade, shade, 0xff }}}, \
    {{{ x1, y1, z1 }, 0, { 0, 0 }, { shade, shade, shade, 0xff }}}, \
    {{{ x2, y2, z2 }, 0, { 0, 0 }, { shade, shade, shade, 0xff }}}, \
    {{{ x3, y3, z3 }, 0, { 0, 0 }, { shade, shade, shade, 0xff }}}
#define H STAGE_BOX_HALF
#define T (2 * STAGE_BOX_HALF)
static const Vtx stage_box_vertices[] = {
    STAGE_BOX_FACE(-H, T, -H,  -H, T,  H,   H, T,  H,   H, T, -H, 0xff), /* top */
    STAGE_BOX_FACE(-H, 0,  H,   H, 0,  H,   H, T,  H,  -H, T,  H, 0xd8), /* +z */
    STAGE_BOX_FACE( H, 0, -H,  -H, 0, -H,  -H, T, -H,   H, T, -H, 0xb0), /* -z */
    STAGE_BOX_FACE( H, 0,  H,   H, 0, -H,   H, T, -H,   H, T,  H, 0xc4), /* +x */
    STAGE_BOX_FACE(-H, 0, -H,  -H, 0,  H,  -H, T,  H,  -H, T, -H, 0xc4), /* -x */
    STAGE_BOX_FACE(-H, 0, -H,   H, 0, -H,   H, 0,  H,  -H, 0,  H, 0x80), /* bottom */
};
#undef H
#undef T

const Gfx stage_disc_dl_box[] = {
    gsDPPipeSync(),
    gsDPSetCombineLERP(SHADE, 0, ENVIRONMENT, 0, 0, 0, 0, SHADE, SHADE, 0, ENVIRONMENT, 0, 0, 0, 0, SHADE),
    gsSPClearGeometryMode(G_LIGHTING),
    gsSPVertex(stage_box_vertices, 24, 0),
    gsSP2Triangles( 0,  1,  2, 0x0,  0,  2,  3, 0x0),
    gsSP2Triangles( 4,  5,  6, 0x0,  4,  6,  7, 0x0),
    gsSP2Triangles( 8,  9, 10, 0x0,  8, 10, 11, 0x0),
    gsSP2Triangles(12, 13, 14, 0x0, 12, 14, 15, 0x0),
    gsSP2Triangles(16, 17, 18, 0x0, 16, 18, 19, 0x0),
    gsSP2Triangles(20, 21, 22, 0x0, 20, 22, 23, 0x0),
    gsDPPipeSync(),
    gsDPSetCombineMode(G_CC_SHADE, G_CC_SHADE),
    gsDPSetEnvColor(255, 255, 255, 255),
    gsSPSetGeometryMode(G_LIGHTING),
    gsSPEndDisplayList(),
};
