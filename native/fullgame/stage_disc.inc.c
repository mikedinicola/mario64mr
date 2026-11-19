/* The disc stage (Castle Grounds' area 2, through the pipe by where Mario starts): its boxes, and its want of any
 * ground of its own. Mario 64 MR's own geometry, nothing of the ROM's. Included in levels/castle_grounds/leveldata.c by
 * patch_sm64ex.py.
 *
 * The disc is an object (bhvStageDisc: it tilts, and changes shape), its mesh and collision made as the game runs
 * (unity_stage.inc.h, geo_stage_disc); the area's own ground is only a floor far below it, there for there to be
 * somewhere to fall (with nothing under it, its edge would be out of bounds, a wall): off the edge, Marios and boxes
 * fall, and before they reach it they're back from the sky, falling onto the disc (unity_stage.inc.h, STAGE_FALL_Y). */

#define STAGE_UNDER_Y -6000 /* (well below STAGE_FALL_Y: nothing reaches it) */
#define STAGE_UNDER_HALF 8000 /* (as far as the level goes: LEVEL_BOUNDARY_MAX, 8192) */
const Collision stage_disc_under_collision[] = {
    COL_INIT(),
    COL_VERTEX_INIT(4),
    COL_VERTEX(-STAGE_UNDER_HALF, STAGE_UNDER_Y, -STAGE_UNDER_HALF),
    COL_VERTEX(-STAGE_UNDER_HALF, STAGE_UNDER_Y,  STAGE_UNDER_HALF),
    COL_VERTEX( STAGE_UNDER_HALF, STAGE_UNDER_Y,  STAGE_UNDER_HALF),
    COL_VERTEX( STAGE_UNDER_HALF, STAGE_UNDER_Y, -STAGE_UNDER_HALF),
    COL_TRI_INIT(SURFACE_DEFAULT, 2),
    COL_TRI(0, 1, 2), /* (facing up) */
    COL_TRI(0, 2, 3),
    COL_TRI_STOP(),
    COL_END(),
};

/* A box: a cube 2 * STAGE_BOX_HALF across standing on its origin, in the colour the object gives it, each face shaded
 * (lit from above) by that colour made darker, face by face (the environment colour: geo_stage_box draws a face at a
 * time). Its four sides and its top are embossed, monochrome, as the side of a coin is: a grey relief the colour is
 * multiplied by (stage_gen.py's box_side: your picture, else the game's own Mario head, made at build time) */
#define STAGE_BOX_HALF 55 /* (laid out touching: unity_stage.inc.h's STAGE_MOSAIC_SPACING) */
#define STAGE_BOX_TEXELS 64 /* (as the texture's declared: any size of picture is drawn across a side) */
static const u8 stage_box_side_texture[] = "levels/castle_grounds/stage_box_side.rgba32";
#define STAGE_BOX_SIDE(x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3) \
    {{{ x0, y0, z0 }, 0, { 0, STAGE_BOX_TEXELS << 5 }, { 0xff, 0xff, 0xff, 0xff }}}, \
    {{{ x1, y1, z1 }, 0, { STAGE_BOX_TEXELS << 5, STAGE_BOX_TEXELS << 5 }, { 0xff, 0xff, 0xff, 0xff }}}, \
    {{{ x2, y2, z2 }, 0, { STAGE_BOX_TEXELS << 5, 0 }, { 0xff, 0xff, 0xff, 0xff }}}, \
    {{{ x3, y3, z3 }, 0, { 0, 0 }, { 0xff, 0xff, 0xff, 0xff }}}
#define H STAGE_BOX_HALF
#define T (2 * STAGE_BOX_HALF)
static const Vtx stage_box_vertices[] = { /* (each face from its picture's bottom left, as seen from outside it) */
    STAGE_BOX_SIDE(-H, 0,  H,   H, 0,  H,   H, T,  H,  -H, T,  H), /* +z */
    STAGE_BOX_SIDE( H, 0, -H,  -H, 0, -H,  -H, T, -H,   H, T, -H), /* -z */
    STAGE_BOX_SIDE( H, 0,  H,   H, 0, -H,   H, T, -H,   H, T,  H), /* +x */
    STAGE_BOX_SIDE(-H, 0, -H,  -H, 0,  H,  -H, T,  H,  -H, T, -H), /* -x */
    STAGE_BOX_SIDE(-H, T,  H,   H, T,  H,   H, T, -H,  -H, T, -H), /* top (its picture's top furthest from the pipe, as the mosaic's) */
    STAGE_BOX_SIDE(-H, 0, -H,   H, 0, -H,   H, 0,  H,  -H, 0,  H), /* bottom */
};
#undef H
#undef T

/* Begun: the embossed picture, and the box's corners; then each side and the top, in its own shade (geo_stage_box
 * sets it) */
const Gfx stage_disc_dl_box_begin[] = {
    gsDPPipeSync(),
    gsDPSetCombineLERP(TEXEL0, 0, ENVIRONMENT, 0, 0, 0, 0, ENVIRONMENT, TEXEL0, 0, ENVIRONMENT, 0, 0, 0, 0, ENVIRONMENT),
    gsSPClearGeometryMode(G_LIGHTING),
    gsSPTexture(0xFFFF, 0xFFFF, 0, G_TX_RENDERTILE, G_ON),
    gsDPLoadTextureBlock(stage_box_side_texture, G_IM_FMT_RGBA, G_IM_SIZ_32b, STAGE_BOX_TEXELS, STAGE_BOX_TEXELS, 0,
                         G_TX_CLAMP, G_TX_CLAMP, 6, 6, G_TX_NOLOD, G_TX_NOLOD),
    gsSPVertex(stage_box_vertices, 24, 0),
    gsSPEndDisplayList(),
};
const Gfx stage_disc_dl_box_faces[5][2] = { /* (+z, -z, +x, -x, top) */
    { gsSP2Triangles( 0,  1,  2, 0x0,  0,  2,  3, 0x0), gsSPEndDisplayList() },
    { gsSP2Triangles( 4,  5,  6, 0x0,  4,  6,  7, 0x0), gsSPEndDisplayList() },
    { gsSP2Triangles( 8,  9, 10, 0x0,  8, 10, 11, 0x0), gsSPEndDisplayList() },
    { gsSP2Triangles(12, 13, 14, 0x0, 12, 14, 15, 0x0), gsSPEndDisplayList() },
    { gsSP2Triangles(16, 17, 18, 0x0, 16, 18, 19, 0x0), gsSPEndDisplayList() },
};
/* The bottom, plain: the colour alone */
const Gfx stage_disc_dl_box_plain[] = {
    gsDPPipeSync(),
    gsSPTexture(0xFFFF, 0xFFFF, 0, G_TX_RENDERTILE, G_OFF),
    gsDPSetCombineLERP(0, 0, 0, ENVIRONMENT, 0, 0, 0, ENVIRONMENT, 0, 0, 0, ENVIRONMENT, 0, 0, 0, ENVIRONMENT),
    gsSPEndDisplayList(),
};
const Gfx stage_disc_dl_box_bottom[] = { gsSP2Triangles(20, 21, 22, 0x0, 20, 22, 23, 0x0), gsSPEndDisplayList() };
const Gfx stage_disc_dl_box_end[] = {
    gsDPPipeSync(),
    gsDPSetCombineMode(G_CC_SHADE, G_CC_SHADE),
    gsDPSetEnvColor(255, 255, 255, 255),
    gsSPSetGeometryMode(G_LIGHTING),
    gsSPEndDisplayList(),
};
