#ifndef SM64_UNITY_OPTIONS_H
#define SM64_UNITY_OPTIONS_H
#include <stdbool.h>
/* The options menu's values (unity_options.inc.h), shared with Unity (sm64unity_options, FullGame's GameOptions:
 * the same order). The graphics ones are choices Unity applies; the counters go up each time their button is
 * pressed. */
enum UnityOption {
    UNITY_OPT_REFRESH,       /* 72, 80, 90, 120 Hz */
    UNITY_OPT_RESOLUTION,    /* 70% to 150%, by 10 */
    UNITY_OPT_ANTIALIASING,  /* off, MSAA 2x, 4x */
    UNITY_OPT_FOVEATION,     /* off, low, medium, high, high top */
    UNITY_OPT_TEXTURES,      /* N64, mipmaps, anisotropic 2x, 4x, 8x, 16x */
    UNITY_OPT_SHARPENING,    /* off, normal, quality */
    UNITY_OPT_BRING_BACK,    /* counter: Mario back into the game */
    UNITY_OPT_DEFAULTS,      /* counter: the graphics back to their defaults */
    UNITY_OPT_MASTER_VOLUME, /* 0-127 */
    UNITY_OPT_MUSIC_VOLUME,
    UNITY_OPT_SFX_VOLUME,
    UNITY_OPT_ENV_VOLUME,
    UNITY_OPT_HUD,           /* 0 hidden, 1 shown */
    UNITY_OPT_HANDS,         /* your hands over the portal: 0 Mario's gloves, 1 your own (passthrough) */
    UNITY_OPT_DIORAMA,       /* a diorama draws: 0 what's near Mario (as the game), 1 the whole level (unity_draw_far) */
    UNITY_OPT_CHEATS,        /* the Cheats menu's switches, one bit each in struct CheatList's order (bit 0 Enable
                                cheats, on by default) */
    UNITY_OPT_HAND_CHEATS,   /* the Cheats menu's switches for what your hands do in the game, a bit each in
                                enum UnityHandCheat's order (UNITY_HAND_CHEATS_INVERTED's the other way round),
                                all on by default */
    UNITY_OPT_COUNT
};
extern unsigned int gUnityOptions[UNITY_OPT_COUNT];
/* Your hands in the game (unity_hands.inc.h, unity_room_objects.inc.h): cheats, so switches in the Cheats menu */
enum UnityHandCheat {
    UNITY_HAND_COLLECT,  /* touch a coin, cap or 1-up to collect it */
    UNITY_HAND_SQUASH,   /* slap a Goomba from above to squash it */
    UNITY_HAND_PICK_UP,  /* pinch, carry, throw and carry out into the room enemies and NPCs */
    UNITY_HAND_CHEST,    /* the treasure chest by the window: enemies, power-up boxes and more Marios out of it */
    UNITY_HAND_STARS,    /* touch a star or key to collect it too (off by default: they're Mario's to reach) */
    UNITY_HAND_CHEAT_COUNT
};
/* The switches kept the other way round in UNITY_OPT_HAND_CHEATS (a bit set: off), so one added after the options
 * were first kept starts on, as they all do */
#define UNITY_HAND_CHEATS_INVERTED (1u << UNITY_HAND_CHEST)
/* The switches off by default (kept as they are: one added after the options were first kept starts off) */
#define UNITY_HAND_CHEATS_OFF (1u << UNITY_HAND_STARS)
/* What UNITY_OPT_HAND_CHEATS holds by default */
#define UNITY_HAND_CHEATS_DEFAULT ((((1u << UNITY_HAND_CHEAT_COUNT) - 1) & ~UNITY_HAND_CHEATS_OFF) ^ UNITY_HAND_CHEATS_INVERTED)
extern bool gUnityHandCheats[UNITY_HAND_CHEAT_COUNT]; /* (the menu's toggles) */
/* Is it on: its switch, and Enable cheats */
int unity_hand_cheat(int which);
/* Each frame, before the game's: the volumes and the HUD into the PC port's settings */
void unity_apply_options(void);
#endif
