import Foundation
import simd

/// Where the window and the game camera are in the room, as the room's renderer last placed them (RoomPlacement)
struct RoomGeometry: Sendable {
    var roomFromView: simd_float4x4   // the game camera's view space (game units) into the room (metres)
    var windowFromRoom: simd_float4x4 // the room into the window's own space (z towards you)
    var halfSize: SIMD2<Float>        // the opening's half width and height, metres
    /// The cartridge is open into the window (closed, nothing goes through it)
    var open = true
    /// The level is a diorama on a table: no window to carry Mario through
    var diorama = false
    /// "PRESS START" on the title screen, in the window's plane (RoomPlacement.startLabel)
    var startLabel: (center: SIMD2<Float>, half: SIMD2<Float>) = (.zero, .zero)
    /// A diorama's level: the room (metres) into the game's world (units), as it was drawn (Diorama.roomFromWorld)
    var worldFromRoom: simd_float4x4?

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
/// - a hand in the window holds the game still (sm64unity_hold_camera);
/// - an enemy or NPC picked up with a pinch can be carried out of the window too, put down in the room and live
///   there (native/fullgame/unity_room_objects.inc.h), picked up again there, and goes back into the game when it's
///   carried or walks back through the window.
///
/// Coordinates: the room in metres; the game's room space in game units (RoomPlacement.unitsPerMetre from the
/// room's origin); the level in the game's world units, through the game camera and the window.
final class MarioCarrier {
    private var held: Int?                       // the hand holding him
    private var holding: Int?                    // the hand holding an enemy or NPC (unity_hands.inc.h)
    private var holdingInRoom = false            // ...out in the room (unity_room_objects.inc.h)
    /// How near a pinch has to be to an enemy or NPC to pick it up, metres
    private let objectReach: Float = 0.04
    private var wasPinching = [false, false]
    private var lastPalm: [SIMD3<Float>?] = [nil, nil]
    private var heldFrom = SIMD3<Float>.zero     // (where he was in the level when picked up: back there if he can't go out)
    var roomHasSurfaces = false

    /// How far below the pinch he hangs (he's held by the top of his head), metres
    private let hang: Float = 0.12

    /// How many can be out in the room at once (UNITY_ROOM_OBJECTS)
    static let roomObjects = 16

    func update(hands: [HandState], geometry g: RoomGeometry, picks: [ChestPick] = []) {
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
        // ...and their joints through the window, fingertips too (which the surface leaves out): what touches a
        // coin or a star collects it (native/fullgame/unity_hands.inc.h)
        Self.touch(hands, where: inGame, world)

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
        sm64unity_hold_camera(onHand == 2 ? 2 : reaching || held != nil || holding != nil ? 1 : 0)

        // Taken out of the treasure chest: by a pinch, held by it at once (in the room, or in the level if the pinch
        // is through the window; anywhere with no room scanned yet, or another Mario out in the room: beside Mario),
        // carried on below; by a look, put down near Mario
        for pick in picks {
            let kind = pick.kind.rawValue
            guard let i = pick.hand, i < hands.count, hands[i].tracked else {
                _ = sm64unity_spawn_near_mario(kind)
                continue
            }
            guard holding == nil, held == nil else { continue }
            let p = hands[i].pinch
            var made: Int32 = 0
            if inGame(p) {
                let w = world(p)
                made = sm64unity_spawn_held(kind, 0, w.x, w.y, w.z)
            } else if roomHasSurfaces {
                let a = p * units
                made = sm64unity_spawn_held(kind, 1, a.x, a.y, a.z)
            }
            if made == 1 {
                holding = i
                holdingInRoom = !inGame(p)
            } else if made == 0 {
                _ = sm64unity_spawn_near_mario(kind)
            }
        }

        // Picking him up; a pinch through the window anywhere else picks up the enemy or NPC nearest it
        for (i, hand) in hands.enumerated() {
            let began = hand.tracked && hand.pinching && !wasPinching[i]
            if began, held == nil, seen >= 1, hand.grabsMario,
               simd_distance(hand.pinch, marioInRoom + SIMD3(0, hang * 0.7, 0)) < 0.12 {
                held = i
                heldFrom = mode >= 2 ? world(marioInRoom) : position
            } else if began, holding == nil, held == nil, mode == 0, !hand.palmUp, inGame(hand.pinch) {
                // (within a few centimetres of it, in the level's units there)
                let at = world(hand.pinch), reach = simd_distance(at, world(hand.pinch + SIMD3(objectReach, 0, 0)))
                if sm64unity_object_grab(at.x, at.y, at.z, reach) == 1 { holding = i; holdingInRoom = false }
            } else if began, holding == nil, held == nil, !hand.palmUp, !inGame(hand.pinch) {
                // (one out in the room)
                let at = hand.pinch * units
                if sm64unity_object_grab_room(at.x, at.y, at.z, objectReach * units) == 1 { holding = i; holdingInRoom = true }
            }
            wasPinching[i] = hand.tracked && hand.pinching
        }

        // Holding it at the pinch, in the game or out in the room (carried through the window, it goes too);
        // letting go, thrown with the hand: in the game, or put down in the room to live there
        if let h = holding {
            let hand = hands[h]
            if hand.tracked && hand.pinching {
                let result: Int32
                if inGame(hand.pinch) {
                    let at = world(hand.pinch)
                    result = sm64unity_object_hold(at.x, at.y, at.z)
                    holdingInRoom = false
                } else {
                    let at = hand.pinch * units
                    // (-1: it can't go out, no room scanned yet: held where it was, in the game)
                    result = roomHasSurfaces ? sm64unity_object_hold_room(at.x, at.y, at.z) : -1
                    if result == 1 { holdingInRoom = true }
                }
                if result == 0 { holding = nil }  // (gone: killed, say)
            } else {
                holding = nil
                let v = hand.velocity / 30  // (metres a frame)
                if holdingInRoom {
                    // (nothing under it: back where it was picked up in the level)
                    _ = sm64unity_object_release_room(v.x * units, v.y * units, v.z * units)
                } else {
                    let w = worldDirection(v)
                    sm64unity_object_release(w.x, w.y, w.z)
                }
                holdingInRoom = false
            }
        }

        // Out in the room, walking back through the window: back into the game there, going the way it was
        var outside = [Float](repeating: 0, count: 8 * Self.roomObjects)
        let count = Int(sm64unity_room_objects(&outside, Int32(Self.roomObjects)))
        for k in 0..<count where outside[k * 8 + 1] == 0 {
            let o = outside[(k * 8)..<(k * 8 + 8)].map { $0 }
            let at = SIMD3(o[2], o[3], o[4]) / units
            guard inGame(at) else { continue }
            let p = world(at), w = worldDirection(SIMD3(o[5], o[6], o[7]) / units)
            _ = sm64unity_room_object_return(Int32(o[0]), p.x, p.y, p.z, w.x, w.y, w.z)
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

    /// A diorama: nothing to carry or stand on, but your fingers over the level collect what they touch (coins,
    /// stars, 1-ups). What's taken out of the treasure chest beside it goes into the level: by a pinch, held at the
    /// pinch (in the level where your fingers are over it) and let go of there; by a look, near Mario
    func touchDiorama(hands: [HandState], geometry g: RoomGeometry, picks: [ChestPick] = []) {
        // (as reset, but what the chest gave a hand stays held, in the level)
        if held != nil || holdingInRoom || g.worldFromRoom == nil {
            let keep = holdingInRoom ? nil : holding
            holding = nil
            reset()
            holding = keep
        } else {
            sm64unity_room_objects_return()
            wasPinching = [false, false]
            lastPalm = [nil, nil]
            sm64unity_room_hands(nil, 0)
            sm64unity_game_hands(nil, 0)
            sm64unity_game_hand_points(nil, 0, 0)
            sm64unity_hold_camera(0)
        }
        guard let worldFromRoom = g.worldFromRoom else {
            for pick in picks { _ = sm64unity_spawn_near_mario(pick.kind.rawValue) }
            return
        }
        func world(_ p: SIMD3<Float>) -> SIMD3<Float> { xyz(worldFromRoom * SIMD4(p, 1)) }
        Self.touch(hands, where: { _ in true }, world)
        for pick in picks {
            guard let i = pick.hand, i < hands.count, hands[i].tracked, holding == nil else {
                _ = sm64unity_spawn_near_mario(pick.kind.rawValue)
                continue
            }
            let w = world(hands[i].pinch)
            switch sm64unity_spawn_held(pick.kind.rawValue, 0, w.x, w.y, w.z) {
            case 1: holding = i
            case 0: _ = sm64unity_spawn_near_mario(pick.kind.rawValue)
            default: break  // (another Mario: put down there)
            }
        }
        if let h = holding {
            let hand = hands.indices.contains(h) ? hands[h] : HandState()
            if hand.tracked && hand.pinching {
                let at = world(hand.pinch)
                if sm64unity_object_hold(at.x, at.y, at.z) == 0 { holding = nil }  // (gone: killed, say)
            } else {
                holding = nil
                let v = xyz(worldFromRoom * SIMD4(hand.velocity / 30, 0))  // (a frame's worth, thrown with the hand)
                sm64unity_object_release(v.x, v.y, v.z)
            }
        }
    }

    /// The hands' joints (fingertips too, which their surface leaves out) where `inside` says, into the game's
    /// world: each touches what is within a centimetre or so of it (native/fullgame/unity_hands.inc.h)
    private static func touch(_ hands: [HandState], where inside: (SIMD3<Float>) -> Bool,
                              _ world: (SIMD3<Float>) -> SIMD3<Float>) {
        var points: [Float] = []
        var radius: Float = 0
        for hand in hands where hand.tracked {
            for p in (hand.joints.isEmpty ? [hand.reach, hand.pinch] : hand.joints) where inside(p) {
                let w = world(p)
                points += [w.x, w.y, w.z]
                if radius == 0 { radius = simd_distance(w, world(p + SIMD3(touchRadius, 0, 0))) }
            }
        }
        _ = points.withUnsafeBufferPointer {
            sm64unity_game_hand_points($0.baseAddress, Int32($0.count / 3), radius)
        }
    }
    /// How near a fingertip has to come to a coin to collect it, metres
    private static let touchRadius: Float = 0.012

    /// The options menu's Bring Mario back: out in the room (or held), back where he was in the level
    func bringBack(geometry g: RoomGeometry?) {
        let mode = sm64unity_carry_mode()
        guard mode != 0 else { return }
        if held == nil, mode == 3, let g, let inRoom = marioInRoom(geometry: g) {
            // (where he went out: the window's point he's nearest, in the level)
            let camera = Self.camera(), viewFromRoom = g.roomFromView.inverse
            let w = g.windowFromRoom * SIMD4(inRoom, 1)
            let edge = g.windowFromRoom.inverse * SIMD4(min(max(w.x, -g.halfSize.x * 0.8), g.halfSize.x * 0.8),
                                                min(max(w.y, -g.halfSize.y * 0.8), g.halfSize.y * 0.8), -0.05, 1)
            heldFrom = xyz(camera.inverse * (viewFromRoom * edge))
        }
        held = nil
        _ = sm64unity_carry(0, heldFrom.x, heldFrom.y, heldFrom.z, 0, 0, 0)
    }

    /// Out of the room: hands let go of
    func reset() {
        if held != nil {
            held = nil
            _ = sm64unity_carry(0, heldFrom.x, heldFrom.y, heldFrom.z, 0, 0, 0)
        }
        if holding != nil {
            holding = nil
            holdingInRoom = false
            sm64unity_object_release(0, 0, 0)  // (out in the room: back where it was picked up)
        }
        sm64unity_room_objects_return()
        wasPinching = [false, false]
        lastPalm = [nil, nil]
        sm64unity_room_hands(nil, 0)
        sm64unity_game_hands(nil, 0)
        sm64unity_game_hand_points(nil, 0, 0)
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
