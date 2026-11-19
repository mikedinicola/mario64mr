import ARKit
import CompositorServices
import Foundation
import os
import simd
import SwiftUI

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

    /// A Sense controller standing in for the hand (its grip is the pinch); the right one doesn't pick Mario up
    var controller = false
    var grabsMario = true

    /// The skeleton's joints (room metres) in `HandState.jointNames`' order; none for a controller
    var joints: [SIMD3<Float>] = []
    /// For Mario's gloves (GloveMesh): the hand's anchor (at the wrist, into the room), and each joint's turn from
    /// its parent's, in the skeleton's own order (`allJoints`); none for a controller
    var anchor: simd_float4x4?
    var jointRotations: [simd_quatf] = []

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
        hand.joints = HandState.jointNames.map(at)
        hand.anchor = anchor.originFromAnchorTransform
        hand.jointRotations = skeleton.allJoints.map { simd_quatf($0.parentFromJointTransform) }

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

extension HandState {
    /// The joints HandTracker keeps, in this order
    static let jointNames: [HandSkeleton.JointName] = [
        .wrist, .forearmArm,
        .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip,
        .indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip,
        .indexFingerTip,
        .middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip,
        .middleFingerTip,
        .ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip,
        .ringFingerTip,
        .littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip,
        .littleFingerTip,
    ]

    #if DEBUG
    /// (the simulator's scripted hands) a skeleton for a hand pinching at `p`, reaching away from `eye`
    static func debugJoints(pinch p: SIMD3<Float>, eye: SIMD3<Float>) -> [SIMD3<Float>] {
        var forward = p - eye
        forward.y = 0
        forward = simd_length(forward) > 1e-3 ? simd_normalize(forward) : SIMD3(0, 0, -1)
        let side = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let wrist = p - forward * 0.1 - SIMD3(0, 0.06, 0)
        let along = simd_normalize(p - wrist)
        var joints = [wrist, wrist - along * 0.25]
        let thumbBase = wrist + side * 0.02 + along * 0.02
        joints += (1...4).map { i in thumbBase + (p - thumbBase) * Float(i) / 4 }
        for (i, offset) in [Float(0.02), 0, -0.02, -0.038].enumerated() {
            let knuckle = wrist + along * 0.09 + side * offset
            let tip = i == 0 ? p : knuckle + along * (0.075 - Float(i) * 0.008) - SIMD3(0, 0.02, 0)
            joints += [wrist + along * 0.03 + side * offset * 0.6, knuckle,
                       knuckle + (tip - knuckle) * 0.45, knuckle + (tip - knuckle) * 0.75, tip]
        }
        return joints
    }
    #endif
}

/// A pinch the system saw you make while looking at something: visionOS gives apps no gaze, only the ray from your
/// eyes to where you looked as a pinch began (the layer's spatial events). Room metres.
struct GazePinch: Sendable {
    let id: Int
    /// New this frame: the pinch just began
    var began: Bool
    /// From your eyes, where you looked when it began
    let origin: SIMD3<Float>, direction: SIMD3<Float>
    /// The hand (0 left, 1 right), if the system says
    let hand: Int?
    /// Where the pinch is now
    var position: SIMD3<Float>?
}

extension GazePinch {
    /// Which of `hands` made it: as the system says, else the tracked pinch nearest it
    func hand(in hands: [HandState]) -> Int? {
        if let hand { return hand }
        guard let p = position else { return nil }
        return hands.indices.filter { hands[$0].tracked }
            .min { simd_distance(hands[$0].pinch, p) < simd_distance(hands[$1].pinch, p) }
    }

    /// Where it meets the plane z = 0 of `space` (from the room), in that space, if in front of the eyes
    func hit(_ spaceFromRoom: simd_float4x4) -> SIMD3<Float>? {
        let o = spaceFromRoom * SIMD4(origin, 1), d = spaceFromRoom * SIMD4(direction, 0)
        guard abs(d.z) > 1e-5 else { return nil }
        let t = -o.z / d.z
        guard t > 0 else { return nil }
        return SIMD3(o.x + d.x * t, o.y + d.y * t, 0)
    }
}

/// Collects the layer's indirect pinches (on the main thread) for the room's render thread
final class GazePinches: @unchecked Sendable {
    private struct State {
        var ids: [SpatialEventCollection.Event.ID: Int] = [:]
        var next = 0
        var active: [Int: GazePinch] = [:]
    }
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    /// Listens to `layer`'s spatial events (call on the main thread)
    @MainActor func listen(to layer: LayerRenderer) {
        layer.onSpatialEvent = { [weak self] events in self?.receive(events) }
    }

    @MainActor private func receive(_ events: SpatialEventCollection) {
        state.withLockUnchecked { state in
            for event in events where event.kind == .indirectPinch {
                let position = event.inputDevicePose.map { SIMD3<Float>($0.pose3D.position.vector) }
                if event.phase != .active {
                    if let id = state.ids.removeValue(forKey: event.id) { state.active[id] = nil }
                    continue
                }
                if let id = state.ids[event.id] {
                    if let position { state.active[id]?.position = position }
                    continue
                }
                guard let ray = event.selectionRay else { continue }
                let id = state.next
                state.next += 1
                state.ids[event.id] = id
                let hand: Int? = switch event.chirality { case .left: 0; case .right: 1; default: nil }
                state.active[id] = GazePinch(id: id, began: true, origin: SIMD3<Float>(ray.origin.vector),
                                             direction: simd_normalize(SIMD3<Float>(ray.direction.vector)),
                                             hand: hand, position: position)
            }
        }
    }

    /// The pinches held now, those begun since the last call marked `began`
    func take() -> [GazePinch] {
        state.withLockUnchecked { state in
            let pinches = state.active.values.sorted { $0.id < $1.id }
            for id in state.active.keys { state.active[id]?.began = false }
            return pinches
        }
    }
}
