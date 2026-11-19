import Foundation
import simd

/// Mario 128 in your room (README, "Mario 128 in your room"): the disc stage played on a real table, or the floor,
/// Mario about 2 cm tall. On the room's render thread.
/// - It begins with Mario floating in front of you, held still by the game (sm64unity_stage_room_begin: carry mode 1,
///   at its world's origin), until a pinch within 4 cm of him takes him; then he hangs from your fingers.
/// - Let go over a surface (a table, the floor) at most 35 cm above it: the stage is put down there, the room's own
///   surfaces about it its ground (sm64unity_stage_room_place), and he drops onto it, the boxes laid out ahead of him,
///   away from you. A real edge (a table's) is the stage's rim; on the floor there's none, and none is made up. Let go
///   anywhere else and he floats there, waiting to be taken again.
/// - From then on it stays where it was put down, and the stick moves him the way you look. It ends with the room
///   (the Digital Crown), back to the flat window.
final class Mario128Stage {
    /// Metres a game unit: Mario (160 units) about 2 cm tall, the box picture about 18 cm across
    static let scale: Float = 1 / 8000
    /// How near his middle a pinch takes him, metres
    static let reach: Float = 0.04
    /// How far above a surface he can be let go of onto it, metres
    static let dropMost: Float = 0.35
    /// His middle above his feet, metres
    static let middle: Float = 80 * scale

    enum Phase: Equatable { case waiting, held(Int), placed }
    private(set) var phase = Phase.waiting
    /// Where his feet are (waiting, held), or the ground the stage was put down on (placed), in the room
    private(set) var at: SIMD3<Float>
    /// The world's turn about the room's up: its -z (the picture, ahead of Mario) away from you
    private var yaw: Float
    private var hang = SIMD3<Float>.zero  // (the pinch from his feet, while held)
    private var wasPinching = [false, false]
    /// Where it was put down: the ground, and his height above it (metres) when let go of
    private(set) var placed: (ground: SIMD3<Float>, height: Float)?

    /// Mario 40 cm in front of you, 30 cm below your eyes
    init(eye: SIMD3<Float>, forward: SIMD3<Float>) {
        let f = Self.level(forward)
        at = eye + f * 0.4 - SIMD3(0, 0.3, 0)
        yaw = Self.yaw(away: f)
    }

    /// A step: your hands (a pinch takes him; letting go over a surface puts him down: `ground` gives the height of
    /// the one under a point, if one's near enough below). True the step he's put down (`placed`)
    func update(hands: [HandState], eye: SIMD3<Float>, ground: (SIMD3<Float>) -> Float?) -> Bool {
        defer { wasPinching = (0..<2).map { $0 < hands.count && hands[$0].tracked && hands[$0].pinching } }
        switch phase {
        case .waiting:
            for i in hands.indices where i < 2 {
                let h = hands[i]
                guard h.tracked, h.pinching, !wasPinching[i],
                      simd_distance(h.pinch, at + SIMD3(0, Self.middle, 0)) < Self.reach else { continue }
                phase = .held(i)
                hang = h.pinch - at
                break
            }
        case .held(let i):
            guard i < hands.count, hands[i].tracked else { phase = .waiting; return false }  // (he waits there)
            if hands[i].pinching {
                at = hands[i].pinch - hang
                return false
            }
            phase = .waiting
            guard let y = ground(at) else { return false }
            yaw = Self.yaw(away: Self.level(at - eye))
            placed = (SIMD3(at.x, y, at.z), at.y - y)
            at = SIMD3(at.x, y, at.z)
            phase = .placed
            return true
        case .placed:
            break
        }
        return false
    }

    /// The game's world (units) into the room (metres): its origin where Mario is held (his feet), or the ground it
    /// was put down on
    func roomFromWorld() -> simd_float4x4 {
        let place = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(at, 1))
        let s = Self.scale
        return place * simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
            * simd_float4x4(diagonal: SIMD4(s, s, s, 1))
    }

    /// Your forward (where you look, flattened) in the game's world: the stick moves Mario that way
    func forwardInWorld(eyeForward: SIMD3<Float>) -> SIMD3<Float> {
        let f = simd_quatf(angle: -yaw, axis: SIMD3(0, 1, 0)).act(SIMD3(eyeForward.x, 0, eyeForward.z))
        return simd_length(f) > 1e-4 ? simd_normalize(f) : SIMD3(0, 0, -1)
    }

    private static func level(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let f = SIMD3(v.x, 0, v.z)
        return simd_length(f) > 1e-3 ? simd_normalize(f) : SIMD3(0, 0, -1)
    }

    /// The turn that takes the world's -z onto `f` (level)
    private static func yaw(away f: SIMD3<Float>) -> Float { atan2(-f.x, -f.z) }
}

extension RoomMesh {
    /// The room about the stage in the game's world (`worldFromRoom`: Mario128Stage's, units), nine s16 a triangle:
    /// what's within the game's reach of it (±7900 units, a metre; a big triangle reaching past it split till its
    /// pieces don't), nearest first as the scanner gave them, at most maxTriangles; those too thin to stand on left out
    func stageTriangles(worldFromRoom: simd_float4x4) -> [Int16] {
        var out: [Int16] = []
        let most: Float = 7900
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, depth: Int) {
            guard out.count < Self.maxTriangles * 9 else { return }
            let lo = simd_min(a, simd_min(b, c)), hi = simd_max(a, simd_max(b, c))
            guard simd_reduce_max(lo) <= most, simd_reduce_min(hi) >= -most else { return }  // (all of it out of reach)
            if simd_reduce_max(simd_max(simd_abs(lo), simd_abs(hi))) > most {
                guard depth < 8 else { return }
                let ab = (a + b) / 2, bc = (b + c) / 2, ca = (c + a) / 2
                for t in [(a, ab, ca), (ab, b, bc), (ca, bc, c), (ab, bc, ca)] { add(t.0, t.1, t.2, depth: depth + 1) }
                return
            }
            let corners = [a, b, c].map { $0.rounded(.toNearestOrEven) }
            guard simd_length(simd_cross(corners[1] - corners[0], corners[2] - corners[0])) > 1 else { return }
            for c in corners { out += [Int16(c.x), Int16(c.y), Int16(c.z)] }
        }
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let w = worldFromRoom * SIMD4(p, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        var i = 0
        while i + 2 < triangles.count, out.count < Self.maxTriangles * 9 {
            add(world(triangles[i]), world(triangles[i + 1]), world(triangles[i + 2]), depth: 0)
            i += 3
        }
        return out
    }

    /// The highest surface facing up under `p` (x, z), from `p` down to `depth` below it (and a centimetre above):
    /// its height
    func ground(under p: SIMD3<Float>, depth: Float) -> Float? {
        var best: Float?
        var i = 0
        let q = SIMD2(p.x, p.z)
        while i + 2 < triangles.count {
            let a = triangles[i], b = triangles[i + 1], c = triangles[i + 2]
            i += 3
            let n = simd_cross(b - a, c - a)
            guard simd_length(n) > 1e-9, simd_normalize(n).y > 0.7 else { continue }
            let a2 = SIMD2(a.x, a.z), b2 = SIMD2(b.x, b.z), c2 = SIMD2(c.x, c.z)
            func side(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { (v.x - u.x) * (q.y - u.y) - (v.y - u.y) * (q.x - u.x) }
            let s0 = side(a2, b2), s1 = side(b2, c2), s2 = side(c2, a2)
            guard (s0 >= 0 && s1 >= 0 && s2 >= 0) || (s0 <= 0 && s1 <= 0 && s2 <= 0) else { continue }
            let y = a.y - (n.x * (p.x - a.x) + n.z * (p.z - a.z)) / n.y  // (the plane through a, at q)
            guard y <= p.y + 0.01, y >= p.y - depth else { continue }
            if best.map({ y > $0 }) ?? true { best = y }
        }
        return best
    }
}
