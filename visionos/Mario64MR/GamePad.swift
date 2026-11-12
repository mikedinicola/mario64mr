import GameController

/// A paired gamepad (DualSense, Xbox...) as the N64 controller: A = A, X / B = B, left trigger = Z, right trigger
/// = R, left bumper = L, right stick = C buttons, menu = Start, d-pad = d-pad (README's layout).
enum GamePad {
    // N64 button bits (PR/os_cont.h)
    static let a: UInt16 = 0x8000, b: UInt16 = 0x4000, z: UInt16 = 0x2000, start: UInt16 = 0x1000
    static let up: UInt16 = 0x0800, down: UInt16 = 0x0400, left: UInt16 = 0x0200, right: UInt16 = 0x0100
    static let l: UInt16 = 0x0020, r: UInt16 = 0x0010
    static let cUp: UInt16 = 0x0008, cDown: UInt16 = 0x0004, cLeft: UInt16 = 0x0002, cRight: UInt16 = 0x0001

    struct State { var buttons: UInt16 = 0; var stickX: Int8 = 0; var stickY: Int8 = 0 }

    /// The current state of the first extended gamepad, or nothing pressed.
    static func read() -> State {
        guard let pad = GCController.controllers().lazy.compactMap(\.extendedGamepad).first else { return State() }
        var state = State()
        func on(_ pressed: Bool, _ bit: UInt16) { if pressed { state.buttons |= bit } }
        on(pad.buttonA.isPressed, a)
        on(pad.buttonB.isPressed || pad.buttonX.isPressed, b)
        on(pad.leftTrigger.isPressed, z)
        on(pad.rightTrigger.isPressed || pad.rightShoulder.isPressed, r)
        on(pad.leftShoulder.isPressed, l)
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
}
