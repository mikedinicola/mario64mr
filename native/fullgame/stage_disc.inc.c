/* The disc stage (Castle Grounds' area 2, through the pipe by where Mario starts): its ground and what Mario stands
 * on. Mario 64 MR's own geometry, drawn with the grass of your ROM's Castle Grounds (outside_09003800). Included in
 * levels/castle_grounds/leveldata.c by patch_sm64ex.py.
 *
 * For now a flat square of grass, 6000 units across at height 0; the disc comes later. Nothing is under it, so Mario
 * can't walk off its edges (out of bounds). */

#define STAGE_DISC_HALF 3000
/* The grass repeats every 512 units: 32 texels, in the vertex's 10.5 fixed point */
#define STAGE_DISC_UV(units) ((units) * 32 * 32 / 512)

static const Vtx stage_disc_ground_vertices[] = {
    {{{ -STAGE_DISC_HALF, 0, -STAGE_DISC_HALF }, 0, { STAGE_DISC_UV(-STAGE_DISC_HALF), STAGE_DISC_UV(-STAGE_DISC_HALF) }, { 0xff, 0xff, 0xff, 0xff }}},
    {{{ -STAGE_DISC_HALF, 0,  STAGE_DISC_HALF }, 0, { STAGE_DISC_UV(-STAGE_DISC_HALF), STAGE_DISC_UV( STAGE_DISC_HALF) }, { 0xff, 0xff, 0xff, 0xff }}},
    {{{  STAGE_DISC_HALF, 0,  STAGE_DISC_HALF }, 0, { STAGE_DISC_UV( STAGE_DISC_HALF), STAGE_DISC_UV( STAGE_DISC_HALF) }, { 0xff, 0xff, 0xff, 0xff }}},
    {{{  STAGE_DISC_HALF, 0, -STAGE_DISC_HALF }, 0, { STAGE_DISC_UV( STAGE_DISC_HALF), STAGE_DISC_UV(-STAGE_DISC_HALF) }, { 0xff, 0xff, 0xff, 0xff }}},
};

const Gfx stage_disc_dl_ground[] = {
    gsDPPipeSync(),
    gsDPSetCombineMode(G_CC_MODULATERGB, G_CC_MODULATERGB),
    gsSPClearGeometryMode(G_LIGHTING),
    gsDPSetTile(G_IM_FMT_RGBA, G_IM_SIZ_16b, 0, 0, G_TX_LOADTILE, 0, G_TX_WRAP | G_TX_NOMIRROR, G_TX_NOMASK, G_TX_NOLOD, G_TX_WRAP | G_TX_NOMIRROR, G_TX_NOMASK, G_TX_NOLOD),
    gsSPTexture(0xFFFF, 0xFFFF, 0, G_TX_RENDERTILE, G_ON),
    gsDPTileSync(),
    gsDPSetTile(G_IM_FMT_RGBA, G_IM_SIZ_16b, 8, 0, G_TX_RENDERTILE, 0, G_TX_WRAP | G_TX_NOMIRROR, 5, G_TX_NOLOD, G_TX_WRAP | G_TX_NOMIRROR, 5, G_TX_NOLOD),
    gsDPSetTileSize(0, 0, 0, (32 - 1) << G_TEXTURE_IMAGE_FRAC, (32 - 1) << G_TEXTURE_IMAGE_FRAC),
    gsDPSetTextureImage(G_IM_FMT_RGBA, G_IM_SIZ_16b, 1, outside_09003800),
    gsDPLoadSync(),
    gsDPLoadBlock(G_TX_LOADTILE, 0, 0, 32 * 32 - 1, CALC_DXT(32, G_IM_SIZ_16b_BYTES)),
    gsSPVertex(stage_disc_ground_vertices, 4, 0),
    gsSP2Triangles(0, 1, 2, 0x0, 0, 2, 3, 0x0),
    gsSPTexture(0xFFFF, 0xFFFF, 0, G_TX_RENDERTILE, G_OFF),
    gsDPPipeSync(),
    gsDPSetCombineMode(G_CC_SHADE, G_CC_SHADE),
    gsSPSetGeometryMode(G_LIGHTING),
    gsSPEndDisplayList(),
};

const Collision stage_disc_collision[] = {
    COL_INIT(),
    COL_VERTEX_INIT(4),
    COL_VERTEX(-STAGE_DISC_HALF, 0, -STAGE_DISC_HALF),
    COL_VERTEX(-STAGE_DISC_HALF, 0,  STAGE_DISC_HALF),
    COL_VERTEX( STAGE_DISC_HALF, 0,  STAGE_DISC_HALF),
    COL_VERTEX( STAGE_DISC_HALF, 0, -STAGE_DISC_HALF),
    COL_TRI_INIT(SURFACE_DEFAULT, 2),
    COL_TRI(0, 1, 2),
    COL_TRI(0, 2, 3),
    COL_TRI_STOP(),
    COL_END(),
};
