import ARKit
import Foundation
import simd

/// A tracked hand as the game thread needs it (room metres)
struct HandState: Sendable {
    var tracked = false
    /// Thumb and index tips together (with hysteresis: closer than 1.5 cm starts it, farther than 3 cm ends it)
    var pinching = false
    /// Between the thumb and index tips: where a pinch holds
    var pinch = SIMD3<Float>.zero
    /// Its velocity, metres a second (over the last tenth of a second)
    var velocity = SIMD3<Float>.zero
    /// The index fingertip: how far the hand reaches (into the window, say)
    var reach = SIMD3<Float>.zero
    /// The palm and fingers as a surface Mario can stand on, three corners a triangle, its front upwards
    var surface: [SIMD3<Float>] = []
    /// The palm's middle, to move Mario with it while he stands on it
    var palm = SIMD3<Float>.zero
    /// The way the palm faces (out of it)
    var palmNormal = SIMD3<Float>(0, -1, 0)

    /// The palm turned up: a pinch made like that is the menu gesture (Start)
    var palmUp: Bool { palmNormal.y > 0.7 }
}

/// Reads both hands each frame (on the room's render thread), for the game thread (RoomLink.hands)
final class HandTracker: @unchecked Sendable {
    let provider = HandTrackingProvider()
    private var hands = [HandState(), HandState()]
    private var history: [[(time: TimeInterval, point: SIMD3<Float>)]] = [[], []]

    static var isSupported: Bool { HandTrackingProvider.isSupported }

    /// Both hands (0 left, 1 right) at `time`
    func update(at time: TimeInterval) -> [HandState] {
        guard provider.state == .running else { return [HandState(), HandState()] }
        let (left, right) = provider.handAnchors(at: time)
        for (index, anchor) in [left, right].enumerated() {
            hands[index] = state(of: anchor, previous: hands[index], index: index, time: time)
        }
        return hands
    }

    private func state(of anchor: HandAnchor?, previous: HandState, index: Int, time: TimeInterval) -> HandState {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else {
            history[index] = []
            return HandState()
        }
        func at(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = anchor.originFromAnchorTransform * skeleton.joint(name).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        var hand = HandState(tracked: true)
        let thumb = at(.thumbTip), indexTip = at(.indexFingerTip)
        let apart = simd_distance(thumb, indexTip)
        hand.pinching = previous.pinching ? apart < 0.03 : apart < 0.015
        hand.pinch = (thumb + indexTip) / 2
        hand.reach = indexTip

        history[index].append((time, hand.pinch))
        history[index].removeAll { time - $0.time > 0.1 }
        if let first = history[index].first, time - first.time > 0.02 {
            hand.velocity = (hand.pinch - first.point) / Float(time - first.time)
        }

        // The palm (wrist to knuckles) and the fingers out to their tips, as a fan of triangles
        let wrist = at(.wrist), indexKnuckle = at(.indexFingerKnuckle), littleKnuckle = at(.littleFingerKnuckle)
        let middleTip = at(.middleFingerTip), littleTip = at(.littleFingerTip)
        hand.palm = (wrist + indexKnuckle + littleKnuckle) / 3
        // (out of the right palm the knuckles turn clockwise from the wrist; the left is its mirror)
        let normal = simd_cross(indexKnuckle - wrist, littleKnuckle - wrist) * (index == 1 ? 1 : -1)
        if simd_length(normal) > 1e-6 { hand.palmNormal = simd_normalize(normal) }
        let corners = [(wrist, indexKnuckle, littleKnuckle), (indexKnuckle, middleTip, littleTip),
                       (indexKnuckle, littleTip, littleKnuckle)]
        for (a, b, c) in corners {
            let up = simd_cross(b - a, c - a).y >= 0  // (front upwards, so a flat palm is a floor)
            hand.surface += up ? [a, b, c] : [a, c, b]
        }
        return hand
    }
}
