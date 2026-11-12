import Foundation
import simd

/// Where the window and the game camera are in the room, as the room's renderer last placed them (RoomPlacement)
struct RoomGeometry: Sendable {
    var roomFromView: simd_float4x4   // the game camera's view space (game units) into the room (metres)
    var windowFromRoom: simd_float4x4 // the room into the window's own space (z towards you)
    var halfSize: SIMD2<Float>        // the opening's half width and height, metres
    /// The cartridge is open into the window (closed, nothing goes through it)
    var open = true
    /// "PRESS START" on the title screen, in the window's plane (RoomPlacement.startLabel)
    var startLabel: (center: SIMD2<Float>, half: SIMD2<Float>) = (.zero, .zero)

    /// A room point in the window's own space
    func inWindow(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let w = windowFromRoom * SIMD4(p, 1)
        return SIMD3(w.x, w.y, w.z)
    }
}

/// Your hands and Mario (README, "Your left hand in the game"), on the game thread before each tick:
/// - a pinch near him picks him up, and carries him, in the game (carry mode 1) while the hand is through the
///   window, in the room (2) outside it;
/// - letting go puts him back in the game (0) inside the window, or into the room (3), thrown with the hand;
/// - out in the room, running or jumping back through the window puts him back in the game;
/// - your hands are surfaces he stands on (sm64unity_room_hands / _game_hands), and move him with them;
/// - a hand in the window holds the game still (sm64unity_hold_camera).
///
/// Coordinates: the room in metres; the game's room space in game units (RoomPlacement.unitsPerMetre from the
/// room's origin); the level in the game's world units, through the game camera and the window.
final class MarioCarrier {
    private var held: Int?                       // the hand holding him
    private var wasPinching = [false, false]
    private var lastPalm: [SIMD3<Float>?] = [nil, nil]
    private var heldFrom = SIMD3<Float>.zero     // (where he was in the level when picked up: back there if he can't go out)
    var roomHasSurfaces = false

    /// How far below the pinch he hangs (he's held by the top of his head), metres
    private let hang: Float = 0.12

    func update(hands: [HandState], geometry g: RoomGeometry) {
        let camera = Self.camera(), worldFromView = camera.inverse
        let viewFromRoom = g.roomFromView.inverse
        func inGame(_ p: SIMD3<Float>) -> Bool {
            let w = g.windowFromRoom * SIMD4(p, 1)
            return g.open && w.z < 0 && abs(w.x) <= g.halfSize.x && abs(w.y) <= g.halfSize.y
        }
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { xyz(worldFromView * (viewFromRoom * SIMD4(p, 1))) }
        func worldDirection(_ v: SIMD3<Float>) -> SIMD3<Float> {
            xyz(worldFromView * (viewFromRoom * SIMD4(v, 0)))
        }
        func roomOfWorld(_ p: SIMD3<Float>) -> SIMD3<Float> { xyz(g.roomFromView * (camera * SIMD4(p, 1))) }
        let units = RoomPlacement.unitsPerMetre

        var state = [Float](repeating: 0, count: 8)
        let seen = sm64unity_mario(&state)
        let mode = sm64unity_carry_mode()
        let position = SIMD3(state[0], state[1], state[2]), velocity = SIMD3(state[3], state[4], state[5])
        let marioInRoom = mode >= 2 ? position / units : roomOfWorld(position)

        // Your hands as surfaces: through the window in the level, else in the room
        var roomTriangles: [Int16] = [], gameTriangles: [Int16] = []
        for hand in hands where hand.tracked {
            var i = 0
            while i + 2 < hand.surface.count {
                let corners = Array(hand.surface[i..<i + 3])
                i += 3
                if corners.allSatisfy(inGame) {
                    Self.append(corners.map(world), to: &gameTriangles)
                } else {
                    Self.append(corners.map { $0 * units }, to: &roomTriangles)
                }
            }
        }
        _ = roomTriangles.withUnsafeBufferPointer { sm64unity_room_hands($0.baseAddress, Int32($0.count / 9)) }
        _ = gameTriangles.withUnsafeBufferPointer { sm64unity_game_hands($0.baseAddress, Int32($0.count / 9)) }

        // Standing on a hand: he moves with it
        let onHand = sm64unity_mario_on_hand()
        if onHand != 0, let standing = nearestHand(to: marioInRoom, hands) {
            if let last = lastPalm[standing] {
                let delta = hands[standing].palm - last
                let d = onHand == 1 ? delta * units : worldDirection(delta)
                sm64unity_displace(d.x, d.y, d.z)
            }
        }
        for i in hands.indices { lastPalm[i] = hands[i].tracked ? hands[i].palm : nil }

        // A hand in the window holds the game still; standing on one there, it starts again from him after
        let reaching = hands.contains { $0.tracked && inGame($0.reach) }
        sm64unity_hold_camera(onHand == 2 ? 2 : reaching || held != nil ? 1 : 0)

        // Picking him up
        for (i, hand) in hands.enumerated() {
            let began = hand.tracked && hand.pinching && !wasPinching[i]
            if began, held == nil, seen >= 1,
               simd_distance(hand.pinch, marioInRoom + SIMD3(0, hang * 0.7, 0)) < 0.12 {
                held = i
                heldFrom = mode >= 2 ? world(marioInRoom) : position
            }
            wasPinching[i] = hand.tracked && hand.pinching
        }

        // Carrying him, and letting him go
        if let h = held {
            let hand = hands[h], at = hand.pinch - SIMD3(0, hang, 0)
            if hand.tracked && hand.pinching {
                let p = inGame(at) ? world(at) : at * units
                _ = sm64unity_carry(inGame(at) ? 1 : 2, p.x, p.y, p.z, 0, 0, 0)
            } else {
                held = nil
                let v = hand.velocity / 30  // (metres a frame)
                if inGame(at) {
                    let p = world(at), w = worldDirection(v)
                    _ = sm64unity_carry(0, p.x, p.y, p.z, w.x, w.y, w.z)
                } else if !roomHasSurfaces
                            || sm64unity_carry(3, at.x * units, at.y * units, at.z * units,
                                               v.x * units, v.y * units, v.z * units) == 0 {
                    // (no room to put him in yet: back where he was picked up)
                    _ = sm64unity_carry(0, heldFrom.x, heldFrom.y, heldFrom.z, 0, 0, 0)
                }
            }
        } else if mode == 3, inGame(marioInRoom) {
            // Back through the window into the game, going the way he was
            let p = world(marioInRoom), w = worldDirection(velocity / units)
            _ = sm64unity_carry(0, p.x, p.y, p.z, w.x, w.y, w.z)
        }
    }

    /// Out of the room: hands let go of
    func reset() {
        if held != nil {
            held = nil
            _ = sm64unity_carry(0, heldFrom.x, heldFrom.y, heldFrom.z, 0, 0, 0)
        }
        wasPinching = [false, false]
        lastPalm = [nil, nil]
        sm64unity_room_hands(nil, 0)
        sm64unity_game_hands(nil, 0)
        sm64unity_hold_camera(0)
    }

    /// Where Mario is in the room, metres (for the debug hand)
    func marioInRoom(geometry g: RoomGeometry) -> SIMD3<Float>? {
        var state = [Float](repeating: 0, count: 8)
        guard sm64unity_mario(&state) != 0 else { return nil }
        let position = SIMD3(state[0], state[1], state[2])
        if sm64unity_carry_mode() >= 2 { return position / RoomPlacement.unitsPerMetre }
        return xyz(g.roomFromView * (Self.camera() * SIMD4(position, 1)))
    }

    private func nearestHand(to p: SIMD3<Float>, _ hands: [HandState]) -> Int? {
        hands.indices.filter { hands[$0].tracked }.min {
            simd_distance(hands[$0].palm, p) < simd_distance(hands[$1].palm, p)
        }
    }

    private static func camera() -> simd_float4x4 {
        guard let m = sm64unity_camera() else { return matrix_identity_float4x4 }
        return simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                             SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
    }

    private static func append(_ corners: [SIMD3<Float>], to triangles: inout [Int16]) {
        guard corners.allSatisfy({ simd_reduce_max(simd_abs($0)) <= 8000 }) else { return }
        for c in corners { triangles += [Int16(c.x.rounded()), Int16(c.y.rounded()), Int16(c.z.rounded())] }
    }
}

private func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) / (v.w == 0 ? 1 : v.w) }
