/* The disc stage's geo layouts (Castle Grounds' area 2): the stage, with Castle Grounds' own sky and camera, and a
 * box (unity_stage.inc.h). Included in levels/castle_grounds/geo.c by patch_sm64ex.py. */
const GeoLayout stage_disc_geo[] = {
   GEO_NODE_SCREEN_AREA(10, SCREEN_WIDTH/2, SCREEN_HEIGHT/2, SCREEN_WIDTH/2, SCREEN_HEIGHT/2),
   GEO_OPEN_NODE(),
      GEO_ZBUFFER(0),
      GEO_OPEN_NODE(),
         GEO_NODE_ORTHO(100),
         GEO_OPEN_NODE(),
            GEO_BACKGROUND(BACKGROUND_OCEAN_SKY, geo_skybox_main),
         GEO_CLOSE_NODE(),
      GEO_CLOSE_NODE(),
      GEO_ZBUFFER(1),
      GEO_OPEN_NODE(),
         GEO_CAMERA_FRUSTUM_WITH_FUNC(45, 100, 20000, geo_camera_fov),
         GEO_OPEN_NODE(),
            GEO_CAMERA(16, 0, 1500, 2500, 0, 1500, -12000, geo_camera_main),
            GEO_OPEN_NODE(),
               GEO_DISPLAY_LIST(LAYER_OPAQUE, stage_disc_dl_ground),
               GEO_RENDER_OBJ(),
               GEO_ASM(0, geo_envfx_main),
            GEO_CLOSE_NODE(),
         GEO_CLOSE_NODE(),
      GEO_CLOSE_NODE(),
   GEO_CLOSE_NODE(),
   GEO_END(),
};

const GeoLayout stage_box_geo[] = {
   GEO_CULLING_RADIUS(300),
   GEO_OPEN_NODE(),
      GEO_SHADOW(SHADOW_SQUARE_PERMANENT, 0x96, 110),
      GEO_OPEN_NODE(),
         GEO_ASM(0, geo_stage_box),
      GEO_CLOSE_NODE(),
   GEO_CLOSE_NODE(),
   GEO_END(),
};
