import Foundation
import simd

/// What the treasure chest holds, in native/fullgame/unity_spawn.inc.h's order (its kinds)
enum SpawnKind: Int32, CaseIterable, Sendable {
    case goomba, bobomb, koopa, chuckya, bully
    case wingCapBox, metalCapBox, vanishCapBox, coinBox, oneUpBox
    case mario

    /// The game's pictures for its tile (two: its left and right halves, side by side)
    var pictures: [String] {
        let a = "gfx/actors/"
        switch self {
        case .goomba: return [a + "goomba/goomba_face.rgba16.png"]
        case .bobomb: return [a + "bobomb/bob-omb_left_side.rgba16.png", a + "bobomb/bob-omb_right_side.rgba16.png"]
        case .koopa: return [a + "koopa/koopa_shell_front.rgba16.png"]
        case .chuckya: return [a + "chuckya/chuckya_eyes.rgba16.png"]
        case .bully: return [a + "bully/bully_left_side.rgba16.png", a + "bully/bully_right_side.rgba16.png"]
        case .wingCapBox: return [a + "exclamation_box/wing_cap_box_front.rgba16.png"]
        case .metalCapBox: return [a + "exclamation_box/metal_cap_box_front.rgba16.png"]
        case .vanishCapBox: return [a + "exclamation_box/vanish_cap_box_front.rgba16.png"]
        case .coinBox: return [a + "exclamation_box/exclamation_box_front.rgba16.png"]
        case .oneUpBox: return [a + "mushroom_1up/1-up_mushroom.rgba16.png"]
        case .mario: return ["gfx/textures/segment2/segment2.05A00.rgba16.png"]  // (the HUD's head)
        }
    }
}

/// Something taken out of the chest: by a pinch on its tile (held by that hand, at the pinch, room metres), or by a
/// look and a pinch (into the level, near Mario)
struct ChestPick: Sendable {
    var kind: SpawnKind
    var hand: Int?
    var at: SIMD3<Float>
}

/// A treasure chest floating just past the window's lower right corner. A fingertip touching it, or a look at it and
/// a pinch, opens it (and closes it again); open, what it holds floats above it as tiles: enemies, power-up boxes and
/// another Mario. A pinch on a tile takes one out held in that hand (MarioCarrier carries it on, into the room or
/// through the window into the level); a look at one and a pinch puts it in the level near Mario.
final class TreasureChest {
    /// Its body (metres): width, the body's height (to the lid's hinge), depth; the lid a half round on top
    static let size = SIMD3<Float>(0.15, 0.065, 0.09)
    static var lidRadius: Float { size.z / 2 }
    /// How far the lid opens, radians
    static let lidOpen: Float = 1.95

    /// The tiles: rows above the chest, enemies and Mario nearer it, the boxes above them. Each row starts at the
    /// chest's left end (the window's side) and runs away from the window, so none is near its edge
    static let rows: [[SpawnKind]] = [
        [.goomba, .bobomb, .koopa, .chuckya, .bully, .mario],
        [.wingCapBox, .metalCapBox, .vanishCapBox, .coinBox, .oneUpBox],
    ]
    static let tileSize: Float = 0.042, tileGap: Float = 0.024

    private(set) var isOpen = false
    /// How far open it is now, 0 to 1 (eased)
    private(set) var openness: Float = 0
    /// Where it is in the room (its body's bottom middle, facing you)
    private(set) var pose = matrix_identity_float4x4
    private(set) var visible = false
    /// Which kinds the level can spawn now (bits by SpawnKind), from the game thread
    var spawnable: UInt32 = 0
    /// The tile a hand's pinch or a look is on, lit up
    private(set) var hovered: SpawnKind?

    private var touching = [false, false]
    private var wasPinching = [false, false]
    /// Hands whose pinch began on a tile: theirs until let go (the window's frame doesn't take them)
    private(set) var claimed = [false, false]
    private var lastToggle: TimeInterval = -10
    private var bob: Float = 0

    /// Each frame, before the cartridge sees the hands: where it floats, and what touches or picks from it. Returns
    /// what was taken out, and the looks it used (not for the window's frame)
    func update(window: RoomPlacement, show: Bool, hands: [HandState], gazes: [GazePinch], eye: SIMD3<Float>,
                time: TimeInterval, dt: Float) -> (picks: [ChestPick], usedGazes: Set<Int>) {
        visible = show
        bob = Float(sin(time * 1.7)) * 0.006
        pose = Self.pose(window: window, eye: eye, bob: bob)
        let goal: Float = isOpen ? 1 : 0
        openness += (goal - openness) * min(1, dt * 7)
        if abs(goal - openness) < 0.002 { openness = goal }
        hovered = nil
        guard show else {
            touching = [false, false]
            claimed = [false, false]
            wasPinching = hands.indices.map { hands[$0].tracked && hands[$0].pinching }
            if wasPinching.count < 2 { wasPinching += [false, false] }
            return ([], [])
        }
        var picks: [ChestPick] = [], used = Set<Int>()
        let chestFromRoom = pose.inverse

        // Pinched on a tile (open): taken out, held by that hand
        for (i, hand) in hands.enumerated() where i < 2 {
            let began = hand.tracked && hand.pinching && !wasPinching[i]
            wasPinching[i] = hand.tracked && hand.pinching
            if !wasPinching[i] { claimed[i] = false }
            guard isOpen, openness > 0.6, hand.tracked else { continue }
            if let (kind, distance) = nearestTile(to: hand.pinch), distance < 0.04 {
                if began { claimed[i] = true }
                if available(kind) { hovered = kind }
                if began, available(kind) { picks.append(ChestPick(kind: kind, hand: i, at: hand.pinch)) }
            }
        }

        // A fingertip touching the chest: opens or closes it
        for (i, hand) in hands.enumerated() where i < 2 {
            let tips = hand.joints.count == HandState.jointNames.count ? [5, 10, 15, 20, 25].map { hand.joints[$0] }
                : (hand.tracked ? [hand.reach] : [])
            let inside = hand.tracked && tips.contains { Self.inChest(chestFromRoom.transform($0)) }
            if inside, !touching[i], time - lastToggle > 0.8 {
                isOpen.toggle()
                lastToggle = time
            }
            touching[i] = inside
        }

        // A look and a pinch: on the chest, opens or closes it; on a tile, puts one in the level near Mario
        for gaze in gazes where gaze.began {
            if isOpen, openness > 0.6, let kind = gazedTile(gaze) {
                used.insert(gaze.id)
                if available(kind) { picks.append(ChestPick(kind: kind, hand: nil, at: .zero)) }
                continue
            }
            if gazedChest(gaze) {
                used.insert(gaze.id)
                if time - lastToggle > 0.3 { isOpen.toggle(); lastToggle = time }
            }
        }
        return (picks, used)
    }

    func available(_ kind: SpawnKind) -> Bool { spawnable & (1 << UInt32(kind.rawValue)) != 0 }

    /// Closed at once (the room closing, a diorama)
    func close() { isOpen = false }

    // ---------------------------------------------------------------- Where things are

    /// Past the window's lower right corner, a little in front of it, turned towards you
    static func pose(window: RoomPlacement, eye: SIMD3<Float>, bob: Float) -> simd_float4x4 {
        let h = window.halfSize
        let corner = window.roomFromWindow.transform(SIMD3(h.x + size.x * 0.5 + 0.10, -h.y - 0.02 + bob, 0.05))
        // (level, its front towards you)
        var toEye = eye - corner
        toEye.y = 0
        let forward = simd_length(toEye) > 1e-4 ? simd_normalize(toEye) : SIMD3(0, 0, 1)
        let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), forward))
        return simd_float4x4(SIMD4(right, 0), SIMD4(0, 1, 0, 0), SIMD4(forward, 0), SIMD4(corner, 1))
    }

    /// A point in the chest's space inside it (with a little margin to touch)
    private static func inChest(_ p: SIMD3<Float>) -> Bool {
        let m: Float = 0.012
        return abs(p.x) <= size.x / 2 + m && abs(p.z) <= size.z / 2 + m && p.y >= -m && p.y <= size.y + lidRadius + m
    }

    /// Each tile's middle (room), facing the same way as the chest
    func tileCenter(_ kind: SpawnKind) -> SIMD3<Float>? {
        for (r, row) in Self.rows.enumerated() {
            guard let c = row.firstIndex(of: kind) else { continue }
            let step = Self.tileSize + Self.tileGap
            let x = -Self.size.x / 2 + Self.tileSize / 2 + Float(c) * step
            // (rising out of the chest as it opens)
            let y = Self.size.y + Self.lidRadius + 0.04 + Float(r) * step
            let rise = Self.ease(openness)
            return pose.transform(SIMD3(x * rise, Self.size.y + (y - Self.size.y) * rise, 0))
        }
        return nil
    }

    /// A tile's quad in the room (unit quad scaled to the tile)
    func tileModel(_ kind: SpawnKind, grow: Float = 1) -> simd_float4x4? {
        guard let c = tileCenter(kind) else { return nil }
        let s = Self.tileSize * Self.ease(openness) * grow
        var m = pose
        m.columns.3 = SIMD4(c, 1)
        return m * simd_float4x4(diagonal: SIMD4(s, s, s, 1))
    }

    private func nearestTile(to p: SIMD3<Float>) -> (SpawnKind, Float)? {
        SpawnKind.allCases.compactMap { kind in tileCenter(kind).map { (kind, simd_distance($0, p)) } }
            .min { $0.1 < $1.1 }
    }

    private func gazedTile(_ gaze: GazePinch) -> SpawnKind? {
        for kind in SpawnKind.allCases {
            guard let model = tileModel(kind), let hit = gaze.hit(model.inverse) else { continue }
            if abs(hit.x) <= 0.65, abs(hit.y) <= 0.65 { return kind }  // (a little bigger than the tile)
        }
        return nil
    }

    private func gazedChest(_ gaze: GazePinch) -> Bool {
        // (its front, as a plane through its middle; and its top, seen from above)
        let front = pose * TreasureChest.translation(0, 0, Self.size.z / 2)
        if let hit = gaze.hit(front.inverse), abs(hit.x) <= Self.size.x / 2 + 0.02,
           hit.y >= -0.02, hit.y <= Self.size.y + Self.lidRadius + 0.02 { return true }
        let top = pose * TreasureChest.translation(0, Self.size.y + Self.lidRadius, 0)
            * simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1))
        if let hit = gaze.hit(top.inverse), abs(hit.x) <= Self.size.x / 2 + 0.02, abs(hit.y) <= Self.size.z / 2 + 0.02 {
            return true
        }
        return false
    }

    /// The lid, turned open about its hinge (along the back of the body's top)
    var lidModel: simd_float4x4 {
        let angle = Self.lidOpen * Self.ease(openness)
        let c = cos(angle), s = sin(angle)
        let turn = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, c, -s, 0), SIMD4(0, s, c, 0), SIMD4(0, 0, 0, 1))
        return pose * Self.translation(0, Self.size.y, -Self.size.z / 2) * turn
    }

    private static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }
    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, y, z, 1)
        return m
    }

    // ---------------------------------------------------------------- Its meshes (PropVertex: position, normal, uv)

    /// The body's wood (its own space: bottom middle at the origin), open at the top; and its dark inside
    static let bodyWood: [Float] = {
        var out: [Float] = []
        let s = size
        box(&out, center: SIMD3(0, s.y / 2, 0), size: SIMD3(s.x, s.y, s.z), skipTop: true)
        return out
    }()
    static let bodyInside: [Float] = {
        var out: [Float] = []
        let s = size, t: Float = 0.006
        // (the inside walls and floor, facing in: a box a wall's thickness smaller, seen from inside)
        box(&out, center: SIMD3(0, s.y / 2 + t / 2, 0), size: SIMD3(s.x - 2 * t, s.y - t, s.z - 2 * t), skipTop: true,
            inward: true)
        // (the rim round the top, between the outside and the inside)
        let y = s.y
        quad(&out, SIMD3(-s.x / 2, y, s.z / 2), SIMD3(s.x / 2, y, s.z / 2), SIMD3(s.x / 2 - t, y, s.z / 2 - t),
             SIMD3(-s.x / 2 + t, y, s.z / 2 - t), n: SIMD3(0, 1, 0))
        quad(&out, SIMD3(s.x / 2, y, -s.z / 2), SIMD3(-s.x / 2, y, -s.z / 2), SIMD3(-s.x / 2 + t, y, -s.z / 2 + t),
             SIMD3(s.x / 2 - t, y, -s.z / 2 + t), n: SIMD3(0, 1, 0))
        quad(&out, SIMD3(-s.x / 2, y, -s.z / 2), SIMD3(-s.x / 2, y, s.z / 2), SIMD3(-s.x / 2 + t, y, s.z / 2 - t),
             SIMD3(-s.x / 2 + t, y, -s.z / 2 + t), n: SIMD3(0, 1, 0))
        quad(&out, SIMD3(s.x / 2, y, s.z / 2), SIMD3(s.x / 2, y, -s.z / 2), SIMD3(s.x / 2 - t, y, -s.z / 2 + t),
             SIMD3(s.x / 2 - t, y, s.z / 2 - t), n: SIMD3(0, 1, 0))
        return out
    }()
    /// The gold: bands round the body near each end, its corners' edges, and the latch on its front
    static let bodyGold: [Float] = {
        var out: [Float] = []
        let s = size, b: Float = 0.012, o: Float = 0.0015
        for x in [-s.x / 2 + b * 1.6, s.x / 2 - b * 1.6] {
            box(&out, center: SIMD3(x, s.y / 2, 0), size: SIMD3(b, s.y + o, s.z + 2 * o))
        }
        box(&out, center: SIMD3(0, s.y / 2, 0), size: SIMD3(s.x + 2 * o, b * 0.5, s.z + 2 * o))
        box(&out, center: SIMD3(0, s.y - 0.012, s.z / 2 + o), size: SIMD3(0.022, 0.026, 0.006))
        return out
    }()
    /// The lid (its hinge's space: the hinge along x at the origin, the lid reaching out along +z), a half round
    /// of wood with gold bands over it
    static let lidWood: [Float] = lid(radius: lidRadius, width: size.x, gold: false)
    static let lidGold: [Float] = {
        var out: [Float] = []
        let b: Float = 0.012
        for x in [-size.x / 2 + b * 1.6, size.x / 2 - b * 1.6] {
            out += lid(radius: lidRadius + 0.0015, width: b, gold: true, at: x)
        }
        // (the latch's top half, at the front edge)
        box(&out, center: SIMD3(0, 0.006, size.z + 0.0015), size: SIMD3(0.022, 0.014, 0.006))
        return out
    }()

    private static func lid(radius r: Float, width: Float, gold: Bool, at x0: Float = 0) -> [Float] {
        var out: [Float] = []
        let steps = 14, half = width / 2, cz = size.z / 2
        func p(_ k: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let a = Float.pi * Float(k) / Float(steps)  // (0 at the back, π at the front)
            let n = SIMD3<Float>(0, sin(a), -cos(a))
            return (SIMD3(0, r * sin(a), cz - r * cos(a)), n)
        }
        for k in 0..<steps {
            let (a, na) = p(k), (b, nb) = p(k + 1)
            let v = [(a + SIMD3(x0 - half, 0, 0), na), (b + SIMD3(x0 - half, 0, 0), nb),
                     (b + SIMD3(x0 + half, 0, 0), nb), (a + SIMD3(x0 + half, 0, 0), na)]
            for i in [0, 2, 1, 0, 3, 2] { vertex(&out, v[i].0, v[i].1) }
        }
        // (its ends, half discs; and its underside, flat, dark inside, for the wood)
        for side: Float in [-1, 1] {
            let x = x0 + side * half
            for k in 0..<steps {
                let a = p(k).0, b = p(k + 1).0
                for q in [SIMD3(x, 0, cz), SIMD3(x, a.y, a.z), SIMD3(x, b.y, b.z)] { vertex(&out, q, SIMD3(side, 0, 0)) }
            }
        }
        if !gold {
            quad(&out, SIMD3(x0 - half, 0, 0), SIMD3(x0 + half, 0, 0), SIMD3(x0 + half, 0, size.z),
                 SIMD3(x0 - half, 0, size.z), n: SIMD3(0, -1, 0))
        }
        return out
    }

    private static func vertex(_ out: inout [Float], _ p: SIMD3<Float>, _ n: SIMD3<Float>) {
        out += [p.x, p.y, p.z, n.x, n.y, n.z, 0.5, 0.5]
    }
    private static func quad(_ out: inout [Float], _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
                             _ d: SIMD3<Float>, n: SIMD3<Float>) {
        for p in [a, b, c, a, c, d] { vertex(&out, p, n) }
    }
    private static func box(_ out: inout [Float], center: SIMD3<Float>, size s: SIMD3<Float>, skipTop: Bool = false,
                            inward: Bool = false) {
        let h = s / 2, k: Float = inward ? -1 : 1
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [  // (normal, and the face's two edges)
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
        ]
        for (n, u, v) in faces {
            if skipTop, n.y > 0.5 { continue }
            let c = center + n * h, du = u * h, dv = v * h
            quad(&out, c - du - dv, c + du - dv, c + du + dv, c - du + dv, n: n * k)
        }
    }
}
