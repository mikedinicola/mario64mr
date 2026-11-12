import Foundation
import simd

/// The cartridge in your room, and the window it opens into (README, "The cartridge"). On the room's render thread,
/// each frame:
/// - closed, it floats where it appeared until you pinch it; held, it follows the pinch, turning upright to face you;
///   let go, it flies with your hand's speed, falls, and comes to rest lying on the first plane it meets (a table,
///   the floor);
/// - pinched with both hands and pulled apart, it opens into the window, as wide as your hands are apart;
/// - open, pinching the frame with one hand moves the window, with two resizes it (up to four times the size it
///   first opens to), and squeezing it narrower than its first size closes it back into the cartridge.
final class Cartridge {
    /// The cartridge's size, metres: width, height, thickness
    static let size = SIMD3<Float>(0.13, 0.095, 0.024)
    /// The window when it first opens, metres wide; and at most four times that
    static let openWidth: Float = 0.6
    static let maxWidth: Float = openWidth * 4
    /// Narrower than this, the window closes (a little under its first size, so it doesn't flicker)
    static let closeWidth: Float = 0.5

    /// The cartridge's own space (x across, y up the label, z out of its front, metres) in the room, while closed
    private(set) var pose = matrix_identity_float4x4
    /// The window (open, or as it was when last open: the game camera stays there)
    private(set) var window: RoomPlacement
    private(set) var isOpen = false

    private var velocity = SIMD3<Float>.zero
    private var resting = true
    /// A hand holding the cartridge or the frame, and where (from the cartridge's centre, or in the window's space)
    private var grips: [Int: SIMD3<Float>] = [:]
    /// Two hands on the frame: their distance and the window's width when the second took hold
    private var resizeFrom: (distance: Float, width: Float)?
    private var wasPinching = [false, false]

    /// The cartridge floating in front of `head`, a little below the eyes; the window would open where it was set
    init(facing head: simd_float4x4) {
        window = RoomPlacement(facing: head)
        let eye = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        var forward = -SIMD3(head.columns.2.x, 0, head.columns.2.z)
        forward = simd_length(forward) > 1e-3 ? simd_normalize(forward) : SIMD3(0, 0, -1)
        pose = Self.upright(at: eye + forward * 0.5 - SIMD3(0, 0.15, 0), facing: eye)
    }

    /// The window open as RoomPlacement places it (with -open, -carry: the room as it was before the cartridge)
    func open(_ placement: RoomPlacement) {
        window = placement
        isOpen = true
        grips = [:]
        resizeFrom = nil
    }

    /// Which hands the cartridge or frame holds (their pinches aren't for the game)
    var holding: Set<Int> { Set(grips.keys) }

    var center: SIMD3<Float> { SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z) }

    func update(hands: [HandState], eye: SIMD3<Float>, planes: [RoomPlane], floor: Float, dt: Float) {
        let dt = min(max(dt, 0), 0.05)
        var hands = Array(hands.prefix(2))  // (untracked hands may be missing: they let go)
        while hands.count < 2 { hands.append(HandState()) }
        var began: [Int] = []
        for (i, hand) in hands.enumerated() {
            let pinching = hand.tracked && hand.pinching
            if pinching && !wasPinching[i] { began.append(i) }
            if !pinching, grips[i] != nil { release(i, hands: hands) }
            wasPinching[i] = pinching
        }
        if isOpen { updateWindow(hands, began: began, eye: eye) } else { updateClosed(hands, began: began, eye: eye) }
        if !isOpen && grips.isEmpty && !resting { fall(planes: planes, floor: floor, dt: dt, eye: eye) }
    }

    // ---------------------------------------------------------------- Closed

    private func updateClosed(_ hands: [HandState], began: [Int], eye: SIMD3<Float>) {
        for i in began where simd_distance(hands[i].pinch, center) < 0.11 {
            grips[i] = center - hands[i].pinch
            resting = false
        }
        let held = grips.keys.sorted()
        if held.count == 2 {
            // Both hands: pulled apart, it opens into the window, between them, at its first size; pulled on,
            // it grows with them
            let a = hands[held[0]].pinch, b = hands[held[1]].pinch, apart = simd_distance(a, b)
            let mid = (a + b) / 2
            pose = Self.upright(at: mid, facing: eye, turning: pose, by: 0.3)
            if apart > Self.size.x + 0.22 {
                window = RoomPlacement(center: mid, facing: eye, width: Self.openWidth)
                isOpen = true
                for i in held { grips[i] = window.roomFromWindow.inverse.transform(hands[i].pinch) }
                resizeFrom = (apart, window.halfSize.x * 2)
            }
        } else if let i = held.first {
            pose = Self.upright(at: hands[i].pinch + grips[i]!, facing: eye, turning: pose, by: 0.15)
        }
    }

    private func release(_ i: Int, hands: [HandState]) {
        grips[i] = nil
        resizeFrom = nil
        if !isOpen && grips.isEmpty {
            velocity = hands[i].velocity
            resting = false
        }
    }

    /// Thrown or dropped: falls, and comes to rest lying on its back on the first plane under it
    private func fall(planes: [RoomPlane], floor: Float, dt: Float, eye: SIMD3<Float>) {
        let half = Self.size.z / 2
        let from = center
        velocity.y -= 9.8 * dt
        velocity *= max(0, 1 - 0.3 * dt)  // (a little air)
        var to = from + velocity * dt
        let bottom = to.y - half
        var landing: Float?
        if velocity.y <= 0 {
            for plane in planes where plane.height <= from.y - half + 0.01 && plane.height >= bottom
                && plane.contains(SIMD2(to.x, to.z)) {
                landing = max(landing ?? -.infinity, plane.height)
            }
            if landing == nil, bottom <= floor { landing = floor }
        }
        if let landing {
            to.y = landing + half
            if velocity.y < -1.5 {  // (a bounce off a hard throw)
                velocity = SIMD3(velocity.x * 0.4, -velocity.y * 0.25, velocity.z * 0.4)
            } else {
                velocity = .zero
                resting = true
            }
        }
        // Turning over onto its back as it settles: lying flat, its top away from you
        var flat = pose
        flat.columns.3 = SIMD4(to, 1)
        if landing != nil || resting {
            var away = SIMD3(to.x - eye.x, 0, to.z - eye.z)
            away = simd_length(away) > 1e-3 ? simd_normalize(away) : SIMD3(0, 0, -1)
            let z = SIMD3<Float>(0, 1, 0), y = away, x = simd_cross(y, z)
            flat = Self.blend(pose, simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(to, 1)),
                              resting ? 1 : 0.5)
        }
        pose = flat
        if to.y < floor - 2 { pose = Self.upright(at: eye + SIMD3(0, -0.15, -0.5), facing: eye); resting = true }
    }

    // ---------------------------------------------------------------- Open

    private func updateWindow(_ hands: [HandState], began: [Int], eye: SIMD3<Float>) {
        let windowFromRoom = window.roomFromWindow.inverse
        let h = window.halfSize
        for i in began {
            // On the frame: just outside the opening's edge, or just inside it, near the window's plane
            let p = windowFromRoom.transform(hands[i].pinch)
            let outer = abs(p.x) < h.x + 0.07 && abs(p.y) < h.y + 0.07
            let inner = abs(p.x) < h.x - 0.04 && abs(p.y) < h.y - 0.04
            if outer && !inner && abs(p.z) < 0.08 { grips[i] = p }
        }
        let held = grips.keys.sorted()
        if held.count == 2 {
            let a = hands[held[0]].pinch, b = hands[held[1]].pinch, apart = simd_distance(a, b)
            if resizeFrom == nil { resizeFrom = (apart, h.x * 2) }
            let width = resizeFrom!.width * apart / max(resizeFrom!.distance, 0.01)
            if width < Self.closeWidth {  // squeezed shut: the cartridge, held between them
                isOpen = false
                pose = Self.upright(at: (a + b) / 2, facing: eye)
                for i in held { grips[i] = center - hands[i].pinch }
                resizeFrom = nil
                resting = false
                return
            }
            window = RoomPlacement(center: (a + b) / 2, facing: eye, width: min(width, Self.maxWidth))
        } else if let i = held.first {
            // Moved by the point held: that point follows the pinch, the window turning to face you
            let grip = grips[i]!, pinch = hands[i].pinch
            var moved = RoomPlacement(center: pinch, facing: eye, width: h.x * 2)
            let offset = moved.roomFromWindow.transformDirection(SIMD3(grip.x, grip.y, 0))
            moved = RoomPlacement(center: pinch - offset, facing: eye, width: h.x * 2)
            window = moved
        }
    }

    // ---------------------------------------------------------------- Poses

    /// Standing upright at `p`, its front (label) turned to `eye`; eased from `from` by `by` (0 to 1) if given
    private static func upright(at p: SIMD3<Float>, facing eye: SIMD3<Float>, turning from: simd_float4x4? = nil,
                                by t: Float = 1) -> simd_float4x4 {
        let target = RoomPlacement(center: p, facing: eye, width: 1).roomFromWindow
        guard let from else { return target }
        return blend(from, target, t)
    }

    /// Between two poses: the rotation slerped, the position `b`'s
    private static func blend(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float) -> simd_float4x4 {
        let qa = simd_quatf(simd_float3x3(columns: (xyz(a.columns.0), xyz(a.columns.1), xyz(a.columns.2))))
        let qb = simd_quatf(simd_float3x3(columns: (xyz(b.columns.0), xyz(b.columns.1), xyz(b.columns.2))))
        let r = simd_float3x3(simd_slerp(qa, qb, t))
        return simd_float4x4(SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), b.columns.3)
    }
}

/// A horizontal surface the cartridge can land on (PlaneDetectionProvider, or the simulator's stand-in room)
struct RoomPlane: Sendable {
    var height: Float
    /// Its outline as triangles on the floor's plane (x, z), three corners each
    var triangles: [SIMD2<Float>]

    func contains(_ p: SIMD2<Float>) -> Bool {
        var i = 0
        while i + 2 < triangles.count {
            let a = triangles[i], b = triangles[i + 1], c = triangles[i + 2]
            i += 3
            func side(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { (v.x - u.x) * (p.y - u.y) - (v.y - u.y) * (p.x - u.x) }
            let d1 = side(a, b), d2 = side(b, c), d3 = side(c, a)
            if !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0)) { return true }
        }
        return false
    }
}

private func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

extension simd_float4x4 {
    func transform(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }
    func transformDirection(_ d: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4(d, 0)
        return SIMD3(v.x, v.y, v.z)
    }
}
