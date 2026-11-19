/* The treasure chest by the window (the host's TreasureChest), drawn as the game's own: Jolly Roger Bay's and Dire
 * Dire Docks' chest, its base and its lid (treasure_chest_base_geo and _lid_geo, built in whatever the level). Included
 * after unity_spawn.inc.h (in surface_load.c).
 *
 * - Two objects that do nothing (bhvStaticObject), put each frame where the host says the chest is (sm64unity_chest:
 *   the room's game units, as Mario's are out there), the lid turned open about its hinge as far as the host has it.
 *   Their draws are tagged 4 (unity_graph_tag), for the host to draw them in the room.
 * - They touch nothing, and aren't the hands' to touch, squash or pick up (unity_object_usable).
 * - Unloaded with the level's objects (a level or area changing), they're made again the next frame; hidden, gone. */
#include "actors/group13.h"
#include "engine/geo_layout.h"
#include "game/memory.h"

/* Where the lid's hinge is on the base (the game's own chest: bhv_treasure_chest_bottom_init) */
#define UNITY_CHEST_HINGE_Y 102.f
#define UNITY_CHEST_HINGE_Z -77.f

static struct { int show; float pos[3]; s16 yaw, lid; float scale; } unity_chest_pose;
static struct Object *unity_chest_parts[2];   /* (the base, the lid) */
static struct GraphNode *unity_chest_models[2];

/* Each part's model, built once into memory of its own (a level's models go with it) */
static struct GraphNode *unity_chest_model(int part) {
    static u64 memory[2][512];
    static struct AllocOnlyPool pools[2];
    if (!unity_chest_models[part]) {
        struct AllocOnlyPool *pool = &pools[part];
        pool->totalSpace = sizeof(memory[part]);
        pool->usedSpace = 0;
        pool->startPtr = pool->freePtr = (u8 *) memory[part];
        unity_chest_models[part] = process_geo_layout(pool, (void *) (part ? treasure_chest_lid_geo : treasure_chest_base_geo));
    }
    return unity_chest_models[part];
}

static int unity_chest_alive(struct Object *o, int part) {
    return o && (o->activeFlags & ACTIVE_FLAG_ACTIVE) && o->behavior == segmented_to_virtual(bhvStaticObject)
        && o->header.gfx.sharedChild == unity_chest_models[part];
}
int unity_chest_part(struct Object *o) {
    return o && ((o == unity_chest_parts[0] && unity_chest_alive(o, 0)) || (o == unity_chest_parts[1] && unity_chest_alive(o, 1)));
}

/* At the start of the objects' frame (unity_spawned_frame): made, moved or gone */
static void unity_chest_frame(void) {
    for (int part = 0; part < 2; part++) {
        struct Object *o = unity_chest_parts[part];
        if (!unity_chest_alive(o, part)) o = unity_chest_parts[part] = NULL;
        if (!unity_chest_pose.show || !gMarioObject) {
            if (o) obj_mark_for_deletion(o);
            unity_chest_parts[part] = NULL;
            continue;
        }
        int made = 0;
        if (!o) {
            struct GraphNode *model = unity_chest_model(part);
            if (!model || !(o = spawn_object(gMarioObject, MODEL_NONE, bhvStaticObject))) continue;
            o->header.gfx.sharedChild = model;
            o->parentObj = o;
            o->oRoom = -1;
            unity_chest_parts[part] = o;
            made = 1;
        }
        float s = unity_chest_pose.scale, *p = unity_chest_pose.pos;
        s16 yaw = unity_chest_pose.yaw;
        o->oPosX = p[0]; o->oPosY = p[1]; o->oPosZ = p[2];
        o->oFaceAngleYaw = o->oMoveAngleYaw = yaw;
        o->oFaceAnglePitch = o->oFaceAngleRoll = 0;
        if (part == 1) {
            /* (the hinge along the back of the base's top, turned with it) */
            o->oPosX += sins(yaw) * UNITY_CHEST_HINGE_Z * s;
            o->oPosY += UNITY_CHEST_HINGE_Y * s;
            o->oPosZ += coss(yaw) * UNITY_CHEST_HINGE_Z * s;
            o->oFaceAnglePitch = unity_chest_pose.lid;
        }
        obj_scale(o, s);
        o->header.gfx.pos[0] = o->oPosX; o->header.gfx.pos[1] = o->oPosY; o->header.gfx.pos[2] = o->oPosZ;
        vec3s_set(o->header.gfx.angle, o->oFaceAnglePitch, o->oFaceAngleYaw, o->oFaceAngleRoll);
        o->header.gfx.node.flags |= GRAPH_RENDER_ACTIVE;
        if (made) unity_skip_object_interpolation(o);
    }
}

/* The host's chest: shown or not; where, the middle of its base's bottom (the room's game units); turned to yaw (radians:
 * its front, the latch's side, towards +z turned by it); its lid open by lid (radians, 0 shut); scale (the game's
 * chest is 184 units wide) */
EXPORT void sm64unity_chest(int show, float x, float y, float z, float yaw, float lid, float scale) {
    unity_chest_pose.show = show;
    unity_chest_pose.pos[0] = x; unity_chest_pose.pos[1] = y; unity_chest_pose.pos[2] = z;
    unity_chest_pose.yaw = (s16) (yaw * (32768.f / (float) M_PI));
    unity_chest_pose.lid = (s16) (-lid * (32768.f / (float) M_PI));  /* (the game's own opens to a pitch below 0) */
    unity_chest_pose.scale = scale;
}
