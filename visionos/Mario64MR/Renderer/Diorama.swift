import Foundation
import simd

/// The level as a diorama on a table (README, "Diorama"): put down by letting go of the window, held by its lower
/// part, over the glowing circle on a plane. On the room's render thread.
/// - The level, about 50 cm across at first (its smallest), stands on the circle, its base (no longer drawn); no sky, no HUD; what's below
///   the table cut away.
/// - It follows Mario up and down, keeping him about 10 cm below your eyes as they were when you put it down (and
///   as far above or below that as you've moved it).
/// - Pinch while looking at it (from anywhere), or pinch its base: with one hand it moves with the hand, up and down
///   too; with two it turns (about the level's middle) and scales. The camera stick turns it (left / right) and zooms
///   it (up / down); clicked in (R3), it brings Mario back to the base's centre, and from then on it turns about
///   there. It ends with the room (the Digital Crown), or on leaving the course.
final class Diorama {
    /// The base's radius, metres (the same whatever the diorama's scale)
    static let radius: Float = 0.25
    /// Metres a game unit, smallest and largest: a level ±8000 units across is about 50 cm to 8 m. It starts at
    /// the smallest.
    static let minScale: Float = 1 / 32000, maxScale: Float = 1 / 2000

    /// Where the base is: its centre on the table, and the table's height
    private(set) var center: SIMD3<Float>
    var table: Float { center.y }
    private var yaw: Float            // the level's turn about the base, radians
    private var scale = Diorama.minScale
    private var marioHeight: Float    // where Mario stays: 10 cm below your eyes when you put it down, moved with it
    private var followY: Float?       // Mario's height, smoothed, game units
    private var anchor: SIMD2<Float>  // the level's point (x, z) on the base's centre
    private var pivot: SIMD2<Float>   // the level's point (x, z) it turns about: its middle, or where R3 recentred it
    private var appear: Float = 0     // 0 to 1: rising out of the circle
    private var recentering: Float = 0  // seconds left gliding Mario back to the base's centre
    private var wasRecentering = false

    /// A hand holding it: by a pinch on the base (followed by hand tracking) or one looking at it (the system's)
    private struct Grip { var from: SIMD3<Float>; let gaze: Int? }
    private var grips: [Int: Grip] = [:]
    private var twoFrom: (angle: Float, distance: Float, yaw: Float, scale: Float)?
    private var wasPinching = [false, false]

    /// Put down at `center` (on the table), the level turned so you look along the game camera's view, Mario at the
    /// base's centre
    init(center: SIMD3<Float>, eye: SIMD3<Float>, camera: simd_float4x4, mario: SIMD3<Float>?,
         levelCenter: SIMD2<Float>?) {
        self.center = center
        marioHeight = eye.y - 0.1
        anchor = mario.map { SIMD2($0.x, $0.z) } ?? .zero
        pivot = levelCenter ?? anchor
        followY = mario?.y
        // The camera's forward in the world, turned onto your forward in the room
        let cameraForward = -SIMD3(camera.columns.0.z, camera.columns.1.z, camera.columns.2.z)
        let lookForward = SIMD3(center.x - eye.x, 0, center.z - eye.z)
        yaw = Self.heading(lookForward) - Self.heading(cameraForward)
    }

    /// The game's world (units) into the room (metres)
    func roomFromWorld() -> simd_float4x4 {
        let s = scale * (0.05 + 0.95 * appear * appear * (3 - 2 * appear))  // (smoothstep: it rises out)
        let marioY = followY ?? 0
        // Mario's height (smoothed) at his height in the room, once it's risen
        let lift = (marioHeight - center.y) * appear
        let rotate = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        let toAnchor = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                     SIMD4(-anchor.x, -marioY, -anchor.y, 1))
        let place = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                  SIMD4(center.x, center.y + lift, center.z, 1))
        return place * rotate * simd_float4x4(diagonal: SIMD4(s, s, s, 1)) * toAnchor
    }

    /// Your forward (where you look, flattened) in the game's world: the stick moves Mario that way
    func forwardInWorld(eyeForward: SIMD3<Float>) -> SIMD3<Float> {
        let f = simd_quatf(angle: -yaw, axis: SIMD3(0, 1, 0)).act(SIMD3(eyeForward.x, 0, eyeForward.z))
        return simd_length(f) > 1e-4 ? simd_normalize(f) : SIMD3(0, 0, -1)
    }

    /// How far the level reaches from the base's centre, metres (about: a level is ±8000 units)
    private var reach: Float { max(Self.radius, 8000 * scale) }

    /// Whether a ray (from your eyes) meets the level: an upright cylinder about the base, from the table to above
    /// your eyes
    func hit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Bool {
        let r = reach, bottom = table - 0.05, top = max(marioHeight + 0.4, table + r)
        let o = SIMD2(origin.x - center.x, origin.z - center.z), d = SIMD2(direction.x, direction.z)
        var t0: Float = 0, t1: Float = 20  // (the ray's stretch inside the cylinder's walls)
        let a = simd_length_squared(d)
        if a < 1e-8 {
            guard simd_length(o) <= r else { return false }
        } else {
            let b = simd_dot(o, d), c = simd_length_squared(o) - r * r, disc = b * b - a * c
            guard disc >= 0 else { return false }
            t0 = max(t0, (-b - disc.squareRoot()) / a)
            t1 = min(t1, (-b + disc.squareRoot()) / a)
        }
        guard t0 <= t1 else { return false }
        let y0 = origin.y + direction.y * t0, y1 = origin.y + direction.y * t1
        return max(y0, y1) >= bottom && min(y0, y1) <= top
    }

    /// The hands holding the base
    var holding: Set<Int> { Set(grips.keys) }

    func update(hands: [HandState], gazes: [GazePinch], cameraStick: SIMD2<Float>, recenter: Bool,
                mario: SIMD3<Float>?, dt: Float, controls: [Int: ControllerControl] = [:]) {
        appear = min(1, appear + dt / 0.8)
        if let mario {  // (follow his height smoothly: jumps barely move it)
            followY = followY.map { $0 + (mario.y - $0) * min(1, dt * 1.5) } ?? mario.y
        }
        // R3: the level glides so Mario stands on the base's centre again (turned and sized as it is), and turns
        // about there from then on
        if recenter && !wasRecentering { recentering = 0.6 }
        wasRecentering = recenter
        if recentering > 0, let mario {
            recentering -= dt
            let target = SIMD2(mario.x, mario.z)
            pivot = target
            anchor = recentering > 0 ? anchor + (target - anchor) * min(1, dt * 8) : target
        }
        var hands = Array(hands.prefix(2))
        while hands.count < 2 { hands.append(HandState()) }
        let gazeById = Dictionary(uniqueKeysWithValues: gazes.map { ($0.id, $0) })
        /// Where hand `i` is now: tracked, or where the system says its pinch is
        func position(_ i: Int) -> SIMD3<Float>? {
            if hands[i].tracked { return hands[i].pinch }
            return grips[i]?.gaze.flatMap { gazeById[$0]?.position }
        }
        // Let go: a pinch on the base when the hand opens, one looking at it when the system ends it
        for (i, grip) in grips {
            let held = grip.gaze.map { gazeById[$0] != nil } ?? (hands[i].tracked && hands[i].pinching)
            if !held { grips[i] = nil; twoFrom = nil }
        }
        // Take hold: pinching the base
        for (i, hand) in hands.enumerated() {
            let pinching = hand.tracked && hand.pinching
            if pinching && !wasPinching[i] && grips[i] == nil {
                let p = hand.pinch, flat = SIMD2(p.x - center.x, p.z - center.z)
                if simd_length(flat) < Self.radius + 0.06, abs(p.y - table) < 0.12 {
                    grips[i] = Grip(from: p, gaze: nil); twoFrom = nil
                }
            }
            wasPinching[i] = pinching
        }
        // Take hold: pinching while looking at it (or anywhere, with the other hand already on it)
        for gaze in gazes where gaze.began {
            guard grips.count == 1 || hit(origin: gaze.origin, direction: gaze.direction) else { continue }
            // (which hand: as the system says, else the tracked pinch nearest it, else whichever is free)
            guard let i = gaze.hand(in: hands) ?? (0..<2).first(where: { grips[$0] == nil }), grips[i]?.gaze == nil else { continue }
            guard let from = hands[i].tracked ? hands[i].pinch : gaze.position else { continue }
            grips[i] = Grip(from: from, gaze: gaze.id); twoFrom = nil
        }
        turnAndZoom(cameraStick, dt: dt)
        let held = grips.keys.sorted()
        if held.count == 2 {
            // Turned about the pivot (the level's middle, or where R3 recentred it) and scaled about the base's
            // centre, as the two pinches turn and part
            guard let a = position(held[0]), let b = position(held[1]) else { return }
            let d = SIMD3(b.x - a.x, 0, b.z - a.z), distance = max(simd_length(d), 0.01), angle = Self.heading(d)
            if twoFrom == nil { twoFrom = (angle, distance, yaw, scale) }
            turn(by: twoFrom!.yaw + angle - twoFrom!.angle - yaw)
            scale = min(max(twoFrom!.scale * distance / twoFrom!.distance, Self.minScale), Self.maxScale)
        } else if let i = held.first, let p = position(i) {
            // Moved as the hand moves: across, and up and down (the base, where it cuts the level, and Mario); a
            // controller's stick in it turns and scales it
            let from = grips[i]!.from
            if let stick = controls[i]?.stick { turnAndZoom(stick, dt: dt) }
            center += p - from
            marioHeight += p.y - from.y
            grips[i]!.from = p
        }
    }

    /// Turns per second, and doublings of the scale per second, with the camera stick pushed all the way
    private static let stickTurn: Float = .pi / 2, stickZoom: Float = 1

    /// The camera stick: left / right turns the level about its pivot (the pivot staying where it is on the table,
    /// the base under another part of it), up / down zooms it in / out about the base's centre (between its smallest
    /// and largest, as two hands do)
    private func turnAndZoom(_ stick: SIMD2<Float>, dt: Float) {
        func dead(_ v: Float) -> Float { abs(v) < 0.15 ? 0 : (v - 0.15 * (v > 0 ? 1 : -1)) / 0.85 }
        let x = dead(stick.x), y = dead(stick.y)
        guard x != 0 || y != 0 else { return }
        let turn = -x * abs(x) * Self.stickTurn * dt  // (pushed right, the level turns clockwise seen from above)
        let zoom = exp2(y * abs(y) * Self.stickZoom * dt)
        let newScale = min(max(scale * zoom, Self.minScale), Self.maxScale)
        // (both hands holding it too: what they've done so far stays, plus the stick's)
        if let from = twoFrom { twoFrom = (from.angle, from.distance, from.yaw + turn, from.scale * newScale / scale) }
        self.turn(by: turn)
        scale = newScale
    }

    /// Turned about the pivot, which stays put: the point on the base moves round it the other way
    private func turn(by angle: Float) {
        let fromPivot = anchor - pivot
        let turned = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0)).act(SIMD3(fromPivot.x, 0, fromPivot.y))
        anchor = pivot + SIMD2(turned.x, turned.z)
        yaw += angle
    }

    /// A direction's heading about the up axis, 0 along -z, as simd_quatf(angle:axis: +y) turns it
    private static func heading(_ v: SIMD3<Float>) -> Float { atan2(-v.x, -v.z) }
}
