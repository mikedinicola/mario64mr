/* Included after surface_load.c so imported room triangles use exactly the
 * original surface construction, sorting and collision partition logic. */
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "game/level_update.h"
#define EXPORT __attribute__((visibility("default")))
static SpatialPartitionCell unity_room_partition[16][16];
static SpatialPartitionCell unity_saved_static[16][16], unity_saved_dynamic[16][16];
static struct Surface *unity_room_surfaces, *unity_old_room_surfaces;
static struct SurfaceNode *unity_room_nodes, *unity_old_room_nodes;
static int unity_room_count, unity_room_depth;
static s16 *unity_saved_environment;
/* Your hands out in the room: moving surfaces, rebuilt every frame like the game's own moving platforms */
#define UNITY_HAND_SURFACES 512
#define UNITY_HAND_NODES 2048
static SpatialPartitionCell unity_hand_partition[16][16];
/* The room's moving surfaces this frame: the hands', and what objects out in the room load as they update (a power-up
 * box's: load_object_collision_model, into the game's surface pool). Each frame it starts again as the hands' alone
 * (unity_load_game_hands, after clear_dynamic_surfaces empties the pool), and what's loaded in the room is kept in it
 * (unity_room_end) */
static SpatialPartitionCell unity_room_dynamic_partition[16][16];
static struct Surface unity_hand_surfaces[UNITY_HAND_SURFACES];
static struct SurfaceNode unity_hand_nodes[UNITY_HAND_NODES];

int unity_room_surface_count(void) { return unity_room_count; }
void unity_room_begin(void) {
    if (unity_room_depth++ != 0) return;
    memcpy(unity_saved_static,gStaticSurfacePartition,sizeof(gStaticSurfacePartition));
    memcpy(unity_saved_dynamic,gDynamicSurfacePartition,sizeof(gDynamicSurfacePartition));
    memcpy(gStaticSurfacePartition,unity_room_partition,sizeof(gStaticSurfacePartition));
    memcpy(gDynamicSurfacePartition,unity_room_dynamic_partition,sizeof(gDynamicSurfacePartition));
    unity_saved_environment=gEnvironmentRegions; gEnvironmentRegions=NULL;
}
void unity_room_end(void) {
    if (unity_room_depth<=0 || --unity_room_depth != 0) return;
    memcpy(unity_room_dynamic_partition,gDynamicSurfacePartition,sizeof(gDynamicSurfacePartition));
    memcpy(gStaticSurfacePartition,unity_saved_static,sizeof(gStaticSurfacePartition));
    memcpy(gDynamicSurfacePartition,unity_saved_dynamic,sizeof(gDynamicSurfacePartition));
    gEnvironmentRegions=unity_saved_environment;
}

/* Replaces the hands' surfaces (room coordinates, as sm64unity_room_mesh); count 0 clears them. */
EXPORT int sm64unity_room_hands(const s16 *triangles,int count) {
    if (unity_room_depth || count<0 || count>UNITY_HAND_SURFACES || (count && !triangles)) return -1;
    struct Surface *saved_surfaces=sSurfacePool;
    struct SurfaceNode *saved_nodes=sSurfaceNodePool;
    int saved_surface_count=gSurfacesAllocated, saved_node_count=gSurfaceNodesAllocated;
    int saved_size=sSurfacePoolSize;
    memcpy(unity_saved_dynamic,gDynamicSurfacePartition,sizeof(gDynamicSurfacePartition));
    memset(gDynamicSurfacePartition,0,sizeof(gDynamicSurfacePartition));
    sSurfacePool=unity_hand_surfaces; sSurfaceNodePool=unity_hand_nodes; sSurfacePoolSize=UNITY_HAND_SURFACES;
    gSurfacesAllocated=gSurfaceNodesAllocated=0;
    int added=0;
    for (int i=0;i<count;i++) {
        const s16 *v=triangles+i*9;
        int ok=1;
        for (int j=0;j<9;j++) if(v[j]<-8000 || v[j]>8000) ok=0;
        int x=upper_cell_index(max_3(v[0],v[3],v[6]))-lower_cell_index(min_3(v[0],v[3],v[6]))+1;
        int z=upper_cell_index(max_3(v[2],v[5],v[8]))-lower_cell_index(min_3(v[2],v[5],v[8]))+1;
        if (!ok || gSurfaceNodesAllocated+x*z>UNITY_HAND_NODES) continue;
        s16 indices[]={0,1,2}, *index=indices;
        struct Surface *surface=read_surface_data((s16 *)v,&index);
        if (surface) { add_surface(surface,TRUE); added++; }
    }
    memcpy(unity_hand_partition,gDynamicSurfacePartition,sizeof(gDynamicSurfacePartition));
    memcpy(unity_room_dynamic_partition,unity_hand_partition,sizeof(unity_hand_partition));
    memcpy(gDynamicSurfacePartition,unity_saved_dynamic,sizeof(gDynamicSurfacePartition));
    sSurfacePool=saved_surfaces; sSurfaceNodePool=saved_nodes; sSurfacePoolSize=saved_size;
    gSurfacesAllocated=saved_surface_count; gSurfaceNodesAllocated=saved_node_count;
    return added;
}

/* Your hands reaching into the game: moving surfaces in the level (game coordinates), loaded each frame with the
 * game's own (unity_load_game_hands, after clear_dynamic_surfaces) while the surface pools have room. */
static s16 unity_game_hand_triangles[UNITY_HAND_SURFACES*9];
static int unity_game_hand_count;
static struct Surface *unity_game_hand_first, *unity_game_hand_end; /* where they are in the pool this frame */
EXPORT int sm64unity_game_hands(const s16 *triangles,int count) {
    if (count<0 || (count && !triangles)) return -1;
    if (count>UNITY_HAND_SURFACES) count=UNITY_HAND_SURFACES;
    memcpy(unity_game_hand_triangles,triangles,count*9*sizeof(s16));
    unity_game_hand_count=count;
    return count;
}
void unity_hands_carry_riders(void);
void unity_load_game_hands(void) {
    if ((gTimeStopState & TIME_STOP_ACTIVE) || unity_room_depth) return;
    /* (the pool was just emptied: what objects out in the room loaded into it last frame is gone too) */
    memcpy(unity_room_dynamic_partition,unity_hand_partition,sizeof(unity_hand_partition));
    unity_hands_carry_riders(); /* (unity_hands.inc.h) what stood on a hand last frame goes with it */
    unity_game_hand_first=&sSurfacePool[gSurfacesAllocated];
    for (int i=0;i<unity_game_hand_count;i++) {
        s16 *v=unity_game_hand_triangles+i*9;
        int x=upper_cell_index(max_3(v[0],v[3],v[6]))-lower_cell_index(min_3(v[0],v[3],v[6]))+1;
        int z=upper_cell_index(max_3(v[2],v[5],v[8]))-lower_cell_index(min_3(v[2],v[5],v[8]))+1;
        if (gSurfacesAllocated+1>=sSurfacePoolSize || gSurfaceNodesAllocated+x*z>=7000) break;
        s16 indices[]={0,1,2}, *index=indices;
        struct Surface *surface=read_surface_data(v,&index);
        if (surface) add_surface(surface,TRUE);
    }
    unity_game_hand_end=&sSurfacePool[gSurfacesAllocated];
}

/* Standing on a hand (1 out in the room, 2 in the game)? The host moves him with it (sm64unity_displace): the game
 * moves Mario with its platforms through their objects, and the hands have none. */
EXPORT int sm64unity_mario_on_hand(void) {
    if (!gMarioState || !gMarioObject || !gMarioState->floor) return 0;
    if ((gMarioState->action & ACT_FLAG_AIR) || gMarioState->pos[1] > gMarioState->floorHeight + 10.0f) return 0;
    struct Surface *floor=gMarioState->floor;
    if (floor>=unity_hand_surfaces && floor<unity_hand_surfaces+UNITY_HAND_SURFACES) return 1;
    if (floor>=unity_game_hand_first && floor<unity_game_hand_end) return 2;
    return 0;
}
EXPORT void sm64unity_displace(float dx,float dy,float dz) {
    if (!gMarioState || !gMarioObject || !isfinite(dx) || !isfinite(dy) || !isfinite(dz)) return;
    gMarioState->pos[0]+=dx; gMarioState->pos[1]+=dy; gMarioState->pos[2]+=dz;
    vec3f_copy(gMarioObject->header.gfx.pos,gMarioState->pos);
}

/* Triangles (9 s16 each, x y z thrice) built as the game builds its static surfaces, in their own new pool, and added to
 * gStaticSurfacePartition as it is: the room's (sm64unity_room_mesh), and the disc stage's out in your room
 * (unity_stage.inc.h). The caller frees *out_surfaces and *out_nodes once nothing can stand on them. How many, or <0 */
/* A scanned surface within 30 degrees of upright is a wall. The game's own rule (read_surface_data, add_surface) makes
 * anything off upright by more than half a degree a floor or a ceiling, which no scanned wall ever is: it would stop
 * Mario as a steep floor's step up, or catch his head as a sliver of ceiling, never push him off it as a wall does.
 * Made upright through its middle, facing the way it did */
static void unity_upright_wall(struct Surface *s) {
    f32 ny=s->normal.y;
    if (ny>=0.5f || ny<=-0.5f) return;
    f32 h=sqrtf(s->normal.x*s->normal.x+s->normal.z*s->normal.z);
    if (h<0.0001f) return;
    s->normal.x/=h; s->normal.y=0; s->normal.z/=h;
    f32 mx=(s->vertex1[0]+s->vertex2[0]+s->vertex3[0])/3.0f, mz=(s->vertex1[2]+s->vertex2[2]+s->vertex3[2])/3.0f;
    s->originOffset=-(s->normal.x*mx+s->normal.z*mz);
}

static int unity_build_static(const s16 *triangles,int count,struct Surface **out_surfaces,struct SurfaceNode **out_nodes) {
    if (count<0 || count>30000 || (count && !triangles)) return -1;
    int node_count=0;
    for (int i=0;i<count;i++) {
        const s16 *v=triangles+i*9;
        for (int j=0;j<9;j++) if(v[j]<-8000 || v[j]>8000)return -2;
        int x=upper_cell_index(max_3(v[0],v[3],v[6]))-lower_cell_index(min_3(v[0],v[3],v[6]))+1;
        int z=upper_cell_index(max_3(v[2],v[5],v[8]))-lower_cell_index(min_3(v[2],v[5],v[8]))+1;
        node_count+=x*z;
    }
    struct Surface *surfaces=calloc(count?count:1,sizeof(*surfaces));
    struct SurfaceNode *nodes=calloc(node_count?node_count:1,sizeof(*nodes));
    if (!surfaces || !nodes) { free(surfaces); free(nodes); return -3; }
    struct Surface *saved_surfaces=sSurfacePool;
    struct SurfaceNode *saved_nodes=sSurfaceNodePool;
    int saved_surface_count=gSurfacesAllocated, saved_node_count=gSurfaceNodesAllocated;
    int saved_size=sSurfacePoolSize;
    sSurfacePool=surfaces; sSurfaceNodePool=nodes; sSurfacePoolSize=count;
    gSurfacesAllocated=gSurfaceNodesAllocated=0;
    for (int i=0;i<count;i++) {
        s16 indices[]={0,1,2}, *index=indices;
        struct Surface *surface=read_surface_data((s16 *)(triangles+i*9),&index);
        if (surface) { unity_upright_wall(surface); add_surface(surface,FALSE); }
    }
    int added=gSurfacesAllocated;
    sSurfacePool=saved_surfaces; sSurfaceNodePool=saved_nodes; sSurfacePoolSize=saved_size;
    gSurfacesAllocated=saved_surface_count; gSurfaceNodesAllocated=saved_node_count;
    *out_surfaces=surfaces; *out_nodes=nodes;
    return added;
}

EXPORT int sm64unity_room_mesh(const s16 *triangles,int count) {
    if (unity_room_depth || count<0 || count>30000 || (count && !triangles)) return -1;
    struct Surface *surfaces; struct SurfaceNode *nodes;
    unity_room_begin();
    memset(gStaticSurfacePartition,0,sizeof(gStaticSurfacePartition));
    int added=unity_build_static(triangles,count,&surfaces,&nodes);
    if (added>=0) {
        memcpy(unity_room_partition,gStaticSurfacePartition,sizeof(gStaticSurfacePartition));
        unity_room_count=added;
    }
    unity_room_end(); /* (the game's own static surfaces back: the room's kept, if it loaded) */
    if (added<0) return added;
    /* The room can reload while Mario is out in it: the surfaces he last stood on stay valid until the next
     * reload, by when his next step has found his floor again */
    free(unity_old_room_surfaces); free(unity_old_room_nodes);
    unity_old_room_surfaces=unity_room_surfaces; unity_old_room_nodes=unity_room_nodes;
    unity_room_surfaces=surfaces; unity_room_nodes=nodes;
    return unity_room_count;
}
