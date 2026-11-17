import Foundation
import simd

/// The cartridge in your room, and the window it opens into (README, "The cartridge"). On the room's render thread,
/// each frame:
/// - closed, it floats where it appeared until you pinch it; held, it follows the pinch, turning upright to face you;
///   let go, it flies with your hand's speed, falls, and comes to rest lying on the first plane it meets (a table,
///   the floor);
/// - pinched with both hands and pulled apart, it opens into the window, as wide as your hands are apart;
/// - open, pinching the window's edge (where it fades out: no frame is drawn) or the handle under it with one hand
///   moves the window, with two resizes it (up to four times the size it first opens to), and squeezing it narrower
///   than its first size closes it back into the cartridge. Pinching while looking at the edge or the handle (from
///   anywhere) takes it as well, moving it as far as your hand moves, times how much farther the window is than your
///   hand.
/// The window is open from the start; with the -cartridge launch argument (or -cart, its scripted demo) the
/// cartridge comes first instead.
final class Cartridge {
    /// Starting as the cartridge, not the window (closing into it works either way)
    static let enabled = ["-cartridge", "-cart"].contains(where: ProcessInfo.processInfo.arguments.contains)

    /// The cartridge's size, metres: width, height, thickness
    static let size = SIMD3<Float>(0.124, 0.084, 0.022)
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
    /// Gone into a diorama (Diorama): not drawn, and hands leave it alone
    private(set) var inDiorama = false

    private var velocity = SIMD3<Float>.zero
    private var resting = true
    /// A hand holding the cartridge or the frame, and where (from the cartridge's centre, or in the window's space)
    private var grips: [Int: SIMD3<Float>] = [:]
    /// Hands holding it by a pinch made looking at it (GazePinch): its id, and where the hand last was
    private var gazeGrips: [Int: (id: Int, last: SIMD3<Float>)] = [:]
    /// Two hands on the frame: their distance and middle, and the window's width and centre, when the second took
    /// hold
    private var resizeFrom: (distance: Float, width: Float, mid: SIMD3<Float>, center: SIMD3<Float>)?
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
        gazeGrips = [:]
        resizeFrom = nil
    }

    /// The hand holding the window alone by its lower part, and the opening's bottom edge's middle in the room (to
    /// put it down as a diorama)
    var heldLow: (hand: Int, bottom: SIMD3<Float>)? {
        guard isOpen, !inDiorama, grips.count == 1, let (hand, grip) = grips.first,
              grip.y < -window.halfSize.y * 0.6 else { return nil }
        return (hand, window.roomFromWindow.transform(SIMD3(0, -window.halfSize.y, 0)))
    }

    /// Into the diorama: the window put away
    func enterDiorama() {
        inDiorama = true
        grips = [:]
        gazeGrips = [:]
        resizeFrom = nil
    }

    /// Out of the diorama: the window back, at `placement`, held by `hand` (if any) at `grip` (in its own space)
    func leaveDiorama(_ placement: RoomPlacement, hand: Int?, grip: SIMD3<Float>) {
        inDiorama = false
        window = placement
        isOpen = true
        grips = [:]
        gazeGrips = [:]
        resizeFrom = nil
        if let hand, hand < 2 { grips[hand] = grip; wasPinching[hand] = true }
    }

    /// Which hands the cartridge or frame holds (their pinches aren't for the game)
    var holding: Set<Int> { Set(grips.keys) }

    var center: SIMD3<Float> { SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z) }

    /// Whether a hand holds it by a pinch made looking at it
    var heldByGaze: Bool { !gazeGrips.isEmpty }

    func update(hands: [HandState], gazes: [GazePinch], eye: SIMD3<Float>, planes: [RoomPlane], floor: Float,
                dt: Float, controls: [Int: ControllerControl] = [:]) {
        let dt = min(max(dt, 0), 0.05)
        var hands = Array(hands.prefix(2))  // (untracked hands may be missing: they let go)
        while hands.count < 2 { hands.append(HandState()) }
        if inDiorama {
            for (i, hand) in hands.enumerated() { wasPinching[i] = hand.tracked && hand.pinching }
            return
        }
        var began: [Int] = []
        let active = Set(gazes.map(\.id))
        for (i, hand) in hands.enumerated() {
            let pinching = hand.tracked && hand.pinching
            if pinching && !wasPinching[i] && gazeGrips[i] == nil { began.append(i) }
            // (a hand holding by a pinch made looking at it lets go when the system ends that pinch)
            let held = gazeGrips[i].map { active.contains($0.id) } ?? pinching
            if !held, grips[i] != nil { release(i, hands: hands) }
            wasPinching[i] = pinching
        }
        if isOpen {
            updateWindow(hands, began: began, gazes: gazes, eye: eye)
        } else {
            updateClosed(hands, began: began, eye: eye)
        }
        for (i, control) in controls where grips[i] != nil && grips.count == 1 {
            useController(control, hand: hands[i], index: i, eye: eye, dt: dt)
        }
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
                resizeFrom = (apart, window.halfSize.x * 2, mid, window.center)
            }
        } else if let i = held.first {
            pose = Self.upright(at: hands[i].pinch + grips[i]!, facing: eye, turning: pose, by: 0.15)
        }
    }

    private func release(_ i: Int, hands: [HandState]) {
        grips[i] = nil
        gazeGrips[i] = nil
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

    /// Whether `p` (in the window's space, on its plane) is on the frame or the handle, with `margin` metres more
    private func onFrame(_ p: SIMD3<Float>, margin: Float = 0) -> Bool {
        let h = window.halfSize, handle = window.handle
        // Just outside the opening's edge, or just inside it; or on the handle, generously
        let outer = abs(p.x) < h.x + 0.07 + margin && abs(p.y) < h.y + 0.07 + margin
        let inner = abs(p.x) < h.x - 0.04 - margin && abs(p.y) < h.y - 0.04 - margin
        let onHandle = abs(p.x - handle.center.x) < handle.half.x + 0.04 + margin
            && abs(p.y - handle.center.y) < handle.half.y + 0.035 + margin
        return (outer && !inner) || onHandle
    }

    /// Where hand `i` is: tracked, or where the system says its pinch is
    private func position(_ i: Int, _ hands: [HandState], _ gazes: [GazePinch]) -> SIMD3<Float> {
        if hands[i].tracked { return hands[i].pinch }
        let id = gazeGrips[i]?.id
        return gazes.first { $0.id == id }?.position ?? gazeGrips[i]?.last ?? hands[i].pinch
    }

    /// How far the window moves for a hand held by a look: as far as the hand, times how much farther it is
    private func reach(_ eye: SIMD3<Float>, hand: SIMD3<Float>) -> Float {
        min(max(simd_distance(eye, window.center) / max(simd_distance(eye, hand), 0.1), 1), 6)
    }

    private func updateWindow(_ hands: [HandState], began: [Int], gazes: [GazePinch], eye: SIMD3<Float>) {
        let windowFromRoom = window.roomFromWindow.inverse
        let h = window.halfSize
        for i in began {
            // On the frame or the handle, near the window's plane
            let p = windowFromRoom.transform(hands[i].pinch)
            if onFrame(p), abs(p.z) < 0.08 { grips[i] = p }
        }
        // Pinched looking at the frame or the handle (or anywhere, the other hand already holding it)
        for gaze in gazes where gaze.began {
            guard let i = gaze.hand(in: hands) ?? (0..<2).first(where: { grips[$0] == nil }),
                  gazeGrips[i] == nil else { continue }
            let p = gaze.hit(windowFromRoom)
            guard p.map({ onFrame($0, margin: 0.02) }) == true || (grips.count == 1 && grips[i] == nil) else { continue }
            guard let from = hands[i].tracked ? hands[i].pinch : gaze.position else { continue }
            grips[i] = p ?? .zero
            gazeGrips[i] = (gaze.id, from)
            resizeFrom = nil
        }
        let held = grips.keys.sorted()
        if held.count == 2 {
            let a = position(held[0], hands, gazes), b = position(held[1], hands, gazes)
            let apart = simd_distance(a, b), mid = (a + b) / 2
            if resizeFrom == nil { resizeFrom = (apart, h.x * 2, mid, window.center) }
            let from = resizeFrom!
            let width = from.width * apart / max(from.distance, 0.01)
            // Held by its frame, the window between the hands; by a look, it moves as their middle does
            let center = gazeGrips.isEmpty ? mid : from.center + (mid - from.mid) * reach(eye, hand: mid)
            if width < Self.closeWidth {  // squeezed shut: the cartridge, held between them
                isOpen = false
                pose = Self.upright(at: center, facing: eye)
                for i in held { grips[i] = center - hands[i].pinch }
                gazeGrips = [:]
                resizeFrom = nil
                resting = false
                return
            }
            window = RoomPlacement(center: center, facing: eye, width: min(width, Self.maxWidth))
        } else if let i = held.first, let gaze = gazeGrips[i] {
            // Held by a look: moved as the hand moves, farther the farther away it is, turning to face you
            let p = position(i, hands, gazes)
            let moved = window.center + (p - gaze.last) * reach(eye, hand: p)
            window = RoomPlacement(center: moved, facing: eye, width: h.x * 2)
            gazeGrips[i]!.last = p
        } else if let i = held.first {
            // Moved by the point held: that point follows the pinch, the window turning to face you
            let grip = grips[i]!, pinch = hands[i].pinch
            var moved = RoomPlacement(center: pinch, facing: eye, width: h.x * 2)
            let offset = moved.roomFromWindow.transformDirection(SIMD3(grip.x, grip.y, 0))
            moved = RoomPlacement(center: pinch - offset, facing: eye, width: h.x * 2)
            window = moved
        }
    }

    // ---------------------------------------------------------------- A Sense controller holding it

    /// Its trigger opens the cartridge into the window, or closes the window; its stick up or down resizes it
    private func useController(_ control: ControllerControl, hand: HandState, index i: Int, eye: SIMD3<Float>,
                               dt: Float) {
        if control.triggerBegan {
            if isOpen {
                isOpen = false
                pose = Self.upright(at: hand.pinch, facing: eye)
                grips[i] = .zero
            } else {
                window = RoomPlacement(center: center, facing: eye, width: Self.openWidth)
                isOpen = true
                grips[i] = window.roomFromWindow.inverse.transform(hand.pinch)
            }
            resizeFrom = nil
        } else if isOpen, abs(control.stick.y) > 0.2 {
            let width = min(max(window.halfSize.x * 2 * exp(control.stick.y * dt), Self.closeWidth), Self.maxWidth)
            window = RoomPlacement(center: window.center, facing: eye, width: width)
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
