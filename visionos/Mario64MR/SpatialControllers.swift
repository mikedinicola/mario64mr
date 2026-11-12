import ARKit
import Foundation
import GameController
import os

/// PS VR2 Sense controllers (spatial controllers, visionOS 26): which is the left and which the right (from ARKit's
/// Accessory), and their buttons and sticks. The room's renderer tracks them (AccessoryTrackingProvider) and makes
/// each a hand; the game thread reads them as the N64 controller, in the README's layouts:
/// - the right one alone (your left hand free for Mario): the one-controller layout;
/// - both: the two-controller layout, the left controller standing in for your left hand (its grip picks Mario up).
final class SpatialControllers: @unchecked Sendable {
    static let shared = SpatialControllers()

    enum Side: Int, Sendable { case left = 0, right = 1 }

    /// One controller's inputs, read now, by GameController's names (PlayStation's in brackets)
    struct Input: Sendable {
        var trigger = false     // (R2 / L2)
        var grip = false        // (R1 / L1)
        var stickClick = false  // (R3 / L3)
        var a = false, b = false   // (the right: a = Cross, b = Circle; the left: x = Square, y = Triangle)
        var menu = false        // (Options on the right, Create on the left)
        var stick = SIMD2<Float>.zero
    }

    private struct Known { var controller: GCController; var accessory: Accessory; var side: Side }
    private let known = OSAllocatedUnfairLock<[ObjectIdentifier: Known]>(initialState: [:])
    private var observers: [NSObjectProtocol] = []
    /// Called (on any thread) when the controllers change: for the room's tracking
    var onChange: (@Sendable ([Accessory]) -> Void)?

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: nil) { [weak self] n in
            if let c = n.object as? GCController { self?.add(c) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: nil) { [weak self] n in
            guard let self, let c = n.object as? GCController else { return }
            known.withLock { $0[ObjectIdentifier(c)] = nil }
            onChange?(accessories)
        })
        for c in GCController.controllers() { add(c) }
    }

    static func isSpatial(_ c: GCController) -> Bool { c.productCategory == GCProductCategorySpatialController }

    private func add(_ controller: GCController) {
        guard Self.isSpatial(controller) else { return }
        Task { [weak self] in
            guard let accessory = try? await Accessory(device: controller) else { return }
            let side: Side = accessory.inherentChirality == .left ? .left : .right
            guard let self else { return }
            known.withLock { $0[ObjectIdentifier(controller)] = Known(controller: controller, accessory: accessory, side: side) }
            onChange?(accessories)
        }
    }

    var accessories: [Accessory] { known.withLock { $0.values.map(\.accessory) } }

    /// Which side an accessory (from tracking) is
    func side(of accessory: Accessory) -> Side? {
        known.withLock { $0.values.first { $0.accessory.id == accessory.id }?.side }
    }

    /// The controllers held now, by side
    func inputs() -> [Side: Input] {
        let controllers = known.withLock { $0.values.map { ($0.controller, $0.side) } }
        var out: [Side: Input] = [:]
        for (controller, side) in controllers {
            let input = controller.input
            func pressed(_ name: GCButtonElementName) -> Bool { input.buttons[name]?.pressedInput.isPressed ?? false }
            var i = Input()
            i.trigger = pressed(.trigger)
            i.grip = pressed(.grip)
            i.stickClick = pressed(.thumbstickButton)
            i.a = side == .right ? pressed(.a) : pressed(.x)
            i.b = side == .right ? pressed(.b) : pressed(.y)
            i.menu = pressed(.menu) || pressed(.options)
            if let stick = input.dpads[.thumbstick]?.xyAxes.value { i.stick = SIMD2(Float(stick.x), Float(stick.y)) }
            out[side] = i
        }
        return out
    }
}

/// What a Sense controller's grip (R1 / L1) holding the cartridge, the window or the diorama's base does with its
/// trigger (R2 / L2: open or close it) and stick (resize; on the base, scale and turn)
struct ControllerControl {
    var triggerBegan = false
    var stick = SIMD2<Float>.zero
}

/// Tracks the Sense controllers in the room (on its render thread), and makes each a hand: its grip (R1 / L1) the
/// pinch
final class ControllerTracker: @unchecked Sendable {
    private(set) var provider: AccessoryTrackingProvider?
    private var wasTrigger: [Bool] = [false, false]

    static var isSupported: Bool { AccessoryTrackingProvider.isSupported }

    /// A provider for the controllers paired now (nil if none: `track` adds them as they come)
    func makeProvider() -> AccessoryTrackingProvider? {
        let accessories = SpatialControllers.shared.accessories
        guard Self.isSupported, !accessories.isEmpty else { return nil }
        let provider = AccessoryTrackingProvider(accessories: accessories)
        self.provider = provider
        return provider
    }

    /// The controllers changed: tracked from now on, in `session`
    func track(_ accessories: [Accessory], in session: ARKitSession) async {
        guard Self.isSupported else { return }
        if let provider, #available(visionOS 27.0, *) {
            try? await provider.updateAccessories(accessories)
        } else if !accessories.isEmpty {  // (visionOS 26: a new provider for them all)
            let provider = AccessoryTrackingProvider(accessories: accessories)
            self.provider = provider
            try? await session.run([provider])
        }
    }

    /// Each tracked controller as its side's hand, at `time`; and the trigger and stick of each
    func hands(at time: TimeInterval) -> [(side: Int, hand: HandState, control: ControllerControl)] {
        guard let provider, provider.state == .running else { return [] }
        let inputs = SpatialControllers.shared.inputs()
        var out: [(Int, HandState, ControllerControl)] = []
        for latest in provider.latestAnchors {
            guard let side = SpatialControllers.shared.side(of: latest.accessory), let input = inputs[side] else { continue }
            let anchor = provider.predictAnchor(for: latest, at: time) ?? latest
            guard anchor.isTracked else { continue }
            let m = anchor.originFromAnchorTransform
            var hand = HandState(tracked: true)
            hand.controller = true
            hand.grabsMario = side == .left
            hand.pinch = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            hand.reach = hand.pinch
            hand.palm = hand.pinch
            hand.pinching = input.grip
            hand.velocity = anchor.velocity
            let i = side.rawValue
            let control = ControllerControl(triggerBegan: input.trigger && !wasTrigger[i], stick: input.stick)
            wasTrigger[i] = input.trigger
            out.append((i, hand, control))
        }
        return out
    }
}
