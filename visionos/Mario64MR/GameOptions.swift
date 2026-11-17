import Foundation

/// The game's options menu (R in the pause menu: native/fullgame/unity_options.inc.h), its values in the game's
/// gUnityOptions (sm64unity_options), in this order. Kept in the app's settings, put back when the game starts.
/// On Vision Pro (the README's "Options"):
/// - Resolution: the room's render quality (LayerRenderer.renderQuality), 100% the headset's own;
/// - Anti-aliasing: MSAA 2x or 4x in the room;
/// - Foveation: on (any level) or off, from the next time the room opens;
/// - Textures: the game's textures with mipmaps, and anisotropic filtering;
/// - Hands: Mario's gloves drawn over your hands where the game is (visionOS drawing your own under it), or your
///   own drawn over everything;
/// - the refresh rate and sharpening are the headset's own (the menu leaves them out on Vision Pro);
/// - the volumes and the HUD the game applies itself.
/// The game thread owns them (`sync`, each tick); the room's renderer reads `Graphics` from RoomLink.
final class GameOptions {
    enum Index: Int {
        case refresh, resolution, antialiasing, foveation, textures, sharpening, bringBack, defaults
        case masterVolume, musicVolume, sfxVolume, envVolume, hud, hands
        case cheats      // the Cheats menu's switches, a bit each (unity_options.h)
        case handCheats  // ...and what your hands do in the game, a bit each
    }

    /// What the room's renderer applies
    struct Graphics: Equatable, Sendable {
        var resolution: Float = 1     // 0.7 to 1.5
        var sampleCount = 4           // 1, 2, 4
        var foveation = true
        var mipmaps = true
        var anisotropy = 4            // 1 (none) to 16
        var gloves = true             // Hands: Mario's gloves (0), or your own (1)

        init() {}
        init(_ o: [UInt32]) {
            resolution = 0.7 + 0.1 * Float(min(o[Index.resolution.rawValue], 8))
            sampleCount = [1, 2, 4][Int(min(o[Index.antialiasing.rawValue], 2))]
            foveation = o[Index.foveation.rawValue] != 0
            let t = Int(min(o[Index.textures.rawValue], 5))
            mipmaps = t >= 1
            anisotropy = t >= 2 ? 1 << (t - 1) : 1
            if o.count > Index.hands.rawValue { gloves = o[Index.hands.rawValue] == 0 }
        }
    }

    private static let key = "options"
    /// The graphics' defaults (unity_mr.c's), for the menu's Defaults
    private static let graphicsDefaults: [UInt32] = [2, 3, 2, 2, 4, 0]
    private static let counters: Set<Int> = [Index.bringBack.rawValue, Index.defaults.rawValue]

    private let values: UnsafeMutablePointer<UInt32>
    private let count: Int
    private var saved: [UInt32]
    private var counted: [UInt32]

    /// After sm64unity_init: the saved values into the game's
    init() {
        values = sm64unity_options()
        count = Int(sm64unity_option_count())
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [Int] ?? []
        for (i, v) in stored.enumerated() where i < count && !Self.counters.contains(i) && v >= 0 {
            values[i] = UInt32(v)
        }
        saved = Array(UnsafeBufferPointer(start: values, count: count))
        counted = saved
    }

    var all: [UInt32] { Array(UnsafeBufferPointer(start: values, count: count)) }
    var graphics: Graphics { Graphics(all) }

    /// Each tick, after the game's: Defaults pressed puts the graphics back; changes are saved. Returns whether
    /// Bring Mario back was pressed.
    func sync() -> Bool {
        var now = all
        let bringBack = now[Index.bringBack.rawValue] != counted[Index.bringBack.rawValue]
        if now[Index.defaults.rawValue] != counted[Index.defaults.rawValue] {
            for (i, v) in Self.graphicsDefaults.enumerated() { values[i] = v }
            values[Index.hands.rawValue] = 0  // (Hands is in the graphics menu too)
            now = all
        }
        counted = now
        if now != saved {
            saved = now
            UserDefaults.standard.set(now.enumerated().map { Self.counters.contains($0) ? 0 : Int($1) }, forKey: Self.key)
        }
        return bringBack
    }

    /// The saved values (the room's layer reads foveation as it opens, before the game may have started)
    static var savedGraphics: Graphics {
        guard let stored = UserDefaults.standard.array(forKey: key) as? [Int], stored.count > Index.textures.rawValue
        else { return Graphics(graphicsDefaults) }
        return Graphics(stored.map { UInt32(max($0, 0)) })
    }
}
