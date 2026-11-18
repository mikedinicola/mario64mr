import GameController
import simd

/// A paired gamepad (DualSense, Xbox...) as the N64 controller: A = A, X / B = B, left trigger = Z, right trigger
/// = R, left bumper = L, right stick = C buttons, menu = Start (in a diorama R3 recentres it, L3 cycles its zoom), d-pad = d-pad (README's layout).
/// On a DualSense: Cross = A, Square / Circle = B, L2 = Z, R2 or R1 = R, L1 = L, Options = Start.
/// PS VR2 Sense controllers: PadReader.
enum GamePad {
    // N64 button bits (PR/os_cont.h)
    static let a: UInt16 = 0x8000, b: UInt16 = 0x4000, z: UInt16 = 0x2000, start: UInt16 = 0x1000
    static let up: UInt16 = 0x0800, down: UInt16 = 0x0400, left: UInt16 = 0x0200, right: UInt16 = 0x0100
    static let l: UInt16 = 0x0020, r: UInt16 = 0x0010
    static let cUp: UInt16 = 0x0008, cDown: UInt16 = 0x0004, cLeft: UInt16 = 0x0002, cRight: UInt16 = 0x0001

    struct State { var buttons: UInt16 = 0; var stickX: Int8 = 0; var stickY: Int8 = 0 }

    static var connected: Bool {
        GCController.controllers().contains { $0.extendedGamepad != nil || SpatialControllers.isSpatial($0) }
    }

    /// The camera stick (the right thumbstick, or the arrow keys), -1 to 1 each way: in a diorama it turns and
    /// zooms the diorama instead of being C buttons (not a Sense controller's: holding the base, its stick does that)
    static func cameraStick() -> SIMD2<Float> {
        var stick = SIMD2<Float>.zero
        for pad in GCController.controllers().filter({ !SpatialControllers.isSpatial($0) }).compactMap(\.extendedGamepad) {
            let c = SIMD2(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
            if abs(c.x) + abs(c.y) > abs(stick.x) + abs(stick.y) { stick = c }
        }
        if stick == .zero, let keys = GCKeyboard.coalesced?.keyboardInput {
            func down(_ code: GCKeyCode) -> Float { keys.button(forKeyCode: code)?.isPressed ?? false ? 1 : 0 }
            stick = SIMD2(down(.rightArrow) - down(.leftArrow), down(.upArrow) - down(.downArrow))
        }
        return stick
    }

    /// The camera stick clicked in (R3, or C on a keyboard): in a diorama it brings Mario back to the base's centre
    static func cameraStickPressed() -> Bool {
        if GCController.controllers().contains(where: { $0.extendedGamepad?.rightThumbstickButton?.isPressed ?? false }) {
            return true
        }
        return GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: .keyC)?.isPressed ?? false
    }

    /// The move stick clicked in (L3 on a gamepad or the left Sense controller, or V on a keyboard): in a diorama it
    /// steps its zoom smallest, middle, largest, and round again
    static func moveStickPressed() -> Bool {
        if GCController.controllers().contains(where: { $0.extendedGamepad?.leftThumbstickButton?.isPressed ?? false }) {
            return true
        }
        if SpatialControllers.shared.inputs()[.left]?.stickClick == true { return true }
        return GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: .keyV)?.isPressed ?? false
    }

    /// Every extended gamepad (not a Sense controller: SpatialControllers reads those) and the keyboard (a Mac's,
    /// in the simulator) together
    static func read() -> State {
        var state = keyboard()
        for pad in GCController.controllers().filter({ !SpatialControllers.isSpatial($0) }).compactMap(\.extendedGamepad) {
            let one = read(pad)
            state.buttons |= one.buttons
            if abs(Int(one.stickX)) + abs(Int(one.stickY)) > abs(Int(state.stickX)) + abs(Int(state.stickY)) {
                (state.stickX, state.stickY) = (one.stickX, one.stickY)
            }
        }
        return state
    }

    private static func read(_ pad: GCExtendedGamepad) -> State {
        var state = State()
        func on(_ pressed: Bool, _ bit: UInt16) { if pressed { state.buttons |= bit } }
        on(pad.buttonA.isPressed, a)
        on(pad.buttonB.isPressed || pad.buttonX.isPressed, b)
        on(pad.leftTrigger.isPressed, z)
        on(pad.rightTrigger.isPressed || pad.rightShoulder.isPressed, r)
        on(pad.leftShoulder.isPressed, l)
        // (not R3 or L3: in a diorama they recentre it and step its zoom, and shouldn't pause the game too)
        on(pad.buttonMenu.isPressed, start)
        on(pad.dpad.up.isPressed, up)
        on(pad.dpad.down.isPressed, down)
        on(pad.dpad.left.isPressed, left)
        on(pad.dpad.right.isPressed, right)
        let c = pad.rightThumbstick
        on(c.yAxis.value > 0.5, cUp)
        on(c.yAxis.value < -0.5, cDown)
        on(c.xAxis.value < -0.5, cLeft)
        on(c.xAxis.value > 0.5, cRight)
        // (sm64ex's SDL controller: ±32768 / 409, about ±80, the N64 stick's range)
        state.stickX = Int8(clamping: Int((pad.leftThumbstick.xAxis.value * 80).rounded()))
        state.stickY = Int8(clamping: Int((pad.leftThumbstick.yAxis.value * 80).rounded()))
        return state
    }

    /// Space = A, Shift = B, Z = Z, Q = L, E = R, Return = Start, WASD = stick, arrows = C buttons
    static func keyboard() -> State {
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return State() }
        var state = State()
        func down(_ code: GCKeyCode) -> Bool { keys.button(forKeyCode: code)?.isPressed ?? false }
        func on(_ code: GCKeyCode, _ bit: UInt16) { if down(code) { state.buttons |= bit } }
        on(.spacebar, a)
        on(.leftShift, b); on(.rightShift, b)
        on(.keyZ, z); on(.keyQ, l); on(.keyE, r)
        on(.returnOrEnter, start)
        on(.upArrow, cUp); on(.downArrow, cDown); on(.leftArrow, cLeft); on(.rightArrow, cRight)
        state.stickX = (down(.keyD) ? 80 : 0) - (down(.keyA) ? 80 : 0)
        state.stickY = (down(.keyW) ? 80 : 0) - (down(.keyS) ? 80 : 0)
        return state
    }
}

/// How far the controller in your hand leans from level with the ground (radians: x its right side down, y its top
/// tipped forward, away from you), from gravity as its motion sensors feel it: a DualSense's, or any paired controller
/// with them. Read while the disc stage's tilting is on (`on`). Game thread.
/// A DualSense (or DualShock 4) gives no gravity of its own, only its total acceleration: gravity is that smoothed,
/// the shakes and jolts of your hands left out. Controllers that do give gravity are read as they give it.
/// The controller's axes are Game Controller's own: x to its right, y towards its top (away from you), z out of its
/// face. Whichever way the reading points (gravity, or the push that holds the controller up), it's taken as pointing
/// down through the controller's back. forwardSign and rightSign flip a lean if it goes the wrong way.
/// While tilting is on, what it reads goes to the console twice a second ("Tilt: ..."): if it's wrong, those say how.
final class ControllerTilt {
    private static let forwardSign: Float = 1, rightSign: Float = 1
    /// How much of each new reading of the acceleration goes into the gravity made from it (per game step: a tenth
    /// of a second or so to settle; the game eases the disc's lean too)
    private static let smoothing: Float = 0.5
    private var smoothed: SIMD3<Float>?
    private var raw = SIMD3<Float>()
    private var source = ""
    private var steps = 0

    func read(on: Bool) -> SIMD2<Float> {
        guard on, var down = gravity() else { smoothed = nil; return .zero }
        if down.z > 0 { down = -down } // (down, through its back, held face up)
        // Each lean from level: right, its right side down (down along +x); forward, its top down (down along +y)
        let right = atan2(down.x, -down.z)
        let forward = atan2(down.y, -down.z)
        let lean = SIMD2(Self.rightSign * right, Self.forwardSign * forward)
        steps += 1
        if steps % 15 == 0 {
            func f(_ v: Float) -> String { String(format: "%+.2f", v) }
            print("Tilt: \(source) \(f(raw.x)) \(f(raw.y)) \(f(raw.z)) -> right \(f(lean.x * 180 / .pi))°, forward \(f(lean.y * 180 / .pi))°")
        }
        return lean
    }

    /// Gravity as the first controller with motion feels it (its sensors turned on, if they must be: a DualSense's)
    private func gravity() -> SIMD3<Float>? {
        for controller in GCController.controllers() {
            guard let motion = controller.motion else { continue }
            if motion.sensorsRequireManualActivation && !motion.sensorsActive { motion.sensorsActive = true }
            if motion.hasGravityAndUserAcceleration {
                let g = SIMD3(Float(motion.gravity.x), Float(motion.gravity.y), Float(motion.gravity.z))
                raw = g; source = "\(controller.vendorName ?? "controller") gravity"
                if simd_length(g) > 0.1 { return simd_normalize(g) }
                continue
            }
            // Its total acceleration (gravity, and however your hands move it), smoothed down to gravity
            let a = SIMD3(Float(motion.acceleration.x), Float(motion.acceleration.y), Float(motion.acceleration.z))
            guard simd_length(a) > 0.1 else { continue } // (its sensors not on yet)
            raw = a; source = "\(controller.vendorName ?? "controller") acceleration"
            let g = smoothed.map { $0 + (a - $0) * Self.smoothing } ?? a
            smoothed = g
            if simd_length(g) > 0.1 { return simd_normalize(g) }
        }
        return nil
    }
}

/// The N64 controller from everything paired: a gamepad, the keyboard, and PS VR2 Sense controllers in the
/// README's Quest layouts (game thread: it keeps the one-controller layout's B tap). A Sense controller whose grip
/// holds the cartridge, the window or the diorama's base (`busy`, by side) is left out: its stick and trigger work
/// those.
final class PadReader {
    private var bSince: Int?          // (one controller: B held since, and whether the stick moved meanwhile)
    private var bSteered = false
    private var rFrames = 0
    private var frame = 0

    func read(busy: Set<Int>) -> GamePad.State {
        frame += 1
        var state = GamePad.read()
        var inputs = SpatialControllers.shared.inputs()
        for side in busy { inputs[SpatialControllers.Side(rawValue: side) ?? .right] = nil }
        var sense = GamePad.State()
        func on(_ pressed: Bool, _ bit: UInt16) { if pressed { sense.buttons |= bit } }
        func stick(_ v: SIMD2<Float>) -> (Int8, Int8) {
            (Int8(clamping: Int((v.x * 80).rounded())), Int8(clamping: Int((v.y * 80).rounded())))
        }
        func c(_ v: SIMD2<Float>) {
            on(v.y > 0.5, GamePad.cUp); on(v.y < -0.5, GamePad.cDown)
            on(v.x < -0.5, GamePad.cLeft); on(v.x > 0.5, GamePad.cRight)
        }
        let left = inputs[.left], right = inputs[.right]
        if let right, let left {
            // Two controllers: left stick, right stick C, R2 or Cross = A, R1 or Circle = B, L2 = Z, Square or
            // Triangle = R (L1, the left grip, is your left hand), R3 or Create = Start (L3 steps a diorama's zoom)
            (sense.stickX, sense.stickY) = stick(left.stick)
            c(right.stick)
            on(right.trigger || right.a, GamePad.a)
            on(right.grip || right.b, GamePad.b)
            on(left.trigger, GamePad.z)
            on(left.a || left.b, GamePad.r)
            on(right.stickClick || left.menu, GamePad.start)
        } else if let right {
            // One controller: stick, R2 = A, Cross = B, R1 = Z, Circle held + stick = C, Circle tapped = R,
            // R3 or Options = Start
            on(right.trigger, GamePad.a)
            on(right.a, GamePad.b)
            on(right.grip, GamePad.z)
            on(right.stickClick || right.menu, GamePad.start)
            let moved = simd_length(right.stick) > 0.5
            if right.b {
                if bSince == nil { bSince = frame; bSteered = false }
                if moved { bSteered = true; c(right.stick) }
            } else {
                if let since = bSince, !bSteered, frame - since < 15 { rFrames = 2 }
                bSince = nil
                (sense.stickX, sense.stickY) = stick(right.stick)
            }
        } else if let left {  // (the left alone: its stick, L2 = A)
            (sense.stickX, sense.stickY) = stick(left.stick)
            on(left.trigger, GamePad.a)
            on(left.menu, GamePad.start)
        }
        if rFrames > 0 { sense.buttons |= GamePad.r; rFrames -= 1 }
        state.buttons |= sense.buttons
        if state.stickX == 0 && state.stickY == 0 { (state.stickX, state.stickY) = (sense.stickX, sense.stickY) }
        return state
    }
}
