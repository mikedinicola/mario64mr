import Foundation
import Metal
import Observation

/// Runs the game (SM64Game) on a thread of its own at 30 game frames a second: the pad in, the frame's sound out to
/// AudioOutput, the frame's draw calls out to `output` for GameRenderer.
@Observable
final class GameHost {
    enum Status: Equatable { case starting, running, failed(String) }

    // What the window shows (set on the main thread)
    private(set) var status = Status.starting
    private(set) var frames = 0
    private(set) var stage = 0
    private(set) var batches = 0
    private(set) var queuedAudio = 0
    private(set) var libraries = ""

    private(set) var hasGamePad = false

    @ObservationIgnored let device = MTLCreateSystemDefaultDevice()
    @ObservationIgnored let output = GameFrames()
    @ObservationIgnored let room = RoomLink()
    @ObservationIgnored private let audio = AudioOutput()
    @ObservationIgnored private var thread: Thread?

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "Game"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 8 << 20  // (the decomp's code keeps big arrays on the stack)
        self.thread = thread
        thread.start()
    }

    private func publish(_ change: @escaping (GameHost) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { change(self) } }
    }

    private func fail(_ message: String) {
        print("Mario 64 MR: \(message)")
        publish { $0.status = .failed(message) }
    }

    private func run() {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("Data") else { return }
        // The game finds its resource pack in its working folder, as sm64ex does: ./res/base.zip
        let gameData = resources.appendingPathComponent("sm64")
        guard FileManager.default.fileExists(atPath: gameData.appendingPathComponent("res/base.zip").path) else {
            return fail("base.zip isn't in the app: run install_mario64mr.py --visionos, then build again")
        }
        FileManager.default.changeCurrentDirectoryPath(gameData.path)
        // Saves (and the options) in the app's Documents folder, which stays when the app is rebuilt
        let saves = URL.documentsDirectory.appendingPathComponent("sm64")
        try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)

        // The other two libraries load with the app (linked); touch each once to show they're there
        let slots = gd_api_texture_slot_count()
        var marioTexture = "no ROM"
        if let rom = try? Data(contentsOf: resources.appendingPathComponent("baserom.us.z64")) {
            var texture = [UInt8](repeating: 0, count: Int(SM64_TEXTURE_WIDTH * SM64_TEXTURE_HEIGHT * 4))
            rom.withUnsafeBytes { sm64_global_init($0.bindMemory(to: UInt8.self).baseAddress, &texture) }
            marioTexture = texture.contains { $0 != 0 } ? "Mario's textures read from the ROM" : "no Mario textures"
        }
        guard let device else { return fail("This device has no Metal GPU") }
        let maker = GameFrameMaker(device: device)
        let size = Int(sm64unity_batch_size())
        guard size == MemoryLayout<SM64UnityBatch>.size else {
            return fail("SM64Game's batches are \(size) bytes, the host expects \(MemoryLayout<SM64UnityBatch>.size)")
        }
        let summary = "SM64Game, Goddard (\(slots) texture slots), LibSM64 (\(marioTexture))"
        publish { $0.libraries = summary }

        guard sm64unity_init(saves.path) == 1 else {
            return fail("The game didn't start (bridge error \(sm64unity_error()))")
        }
        audio.start()
        publish { $0.status = .running }

        #if DEBUG
        let demo = ProcessInfo.processInfo.arguments.contains("-demo")
        let carryDemo = ProcessInfo.processInfo.arguments.contains("-carry")
        #endif
        let carrier = MarioCarrier()
        let period = 1.0 / 30
        var deadline = Date.now.timeIntervalSinceReferenceDate
        var frame = 0
        while !Thread.current.isCancelled {
            var pad = GamePad.read()
            #if DEBUG
            if demo { pad = Self.demoInput(frame) }
            #endif
            // In the room: the level unculled (it's seen from your eyes, not the game camera), billboards facing you
            let room = self.room.current
            sm64unity_mr_geometry(room.on ? 1 : 0)
            if let triangles = room.roomTriangles {  // (the room, for Mario out in it)
                self.room.update { $0.roomTriangles = nil }
                let loaded = triangles.withUnsafeBufferPointer { sm64unity_room_mesh($0.baseAddress, Int32($0.count / 9)) }
                if loaded < 0 { print("Mario 64 MR: the room didn't load (\(loaded))") }
                carrier.roomHasSurfaces = loaded > 0
            }
            // Your hands and Mario
            if room.on, let geometry = room.geometry {
                var hands = room.hands
                #if DEBUG
                if demo, carryDemo { hands = demoHand(frame, carrier: carrier, geometry: geometry, to: room.debugRelease) }
                #endif
                carrier.update(hands: hands, geometry: geometry)
            } else {
                carrier.reset()
            }
            if room.on, let head = room.head {
                sm64unity_billboards(1, head.x, head.y, head.z, room.up.x, room.up.y, room.up.z)
            } else {
                sm64unity_billboards(0, 0, 0, 0, 0, 1, 0)
            }
            if room.on, let facing = room.facing {
                sm64unity_room_facing(1, facing.x, facing.y)
            } else {
                sm64unity_room_facing(0, 0, 0)
            }
            sm64unity_audio_buffered(Int32(audio.buffered))
            guard sm64unity_tick(pad.buttons, pad.stickX, pad.stickY) == 1 else {
                return fail("The game stopped (bridge error \(sm64unity_error()))")
            }
            var count: Int32 = 0
            if let samples = sm64unity_audio(&count), count > 0 {
                audio.push(samples, count: Int(count))
            }
            // 60 fps build: the tick drew the frame between the last tick and this one, shown now; render_current
            // draws this tick's own, shown half a tick later
            let between = maker.make()
            if sm64unity_interpolates() == 1, sm64unity_render_current() == 1 {
                output.publish(between, then: maker.make(), after: period / 2)
            } else {
                output.publish(between)
            }
            frame += 1
            if frame % 15 == 0 {
                let (stage, batches, queued) = (Int(sm64unity_stage()), between.draws.count, audio.buffered)
                let pad = GamePad.connected
                publish {
                    $0.frames = frame; $0.stage = stage; $0.batches = batches; $0.queuedAudio = queued
                    $0.hasGamePad = pad
                }
            }
            deadline += period
            let now = Date.now.timeIntervalSinceReferenceDate
            if deadline > now {
                Thread.sleep(forTimeInterval: deadline - now)
            } else if now - deadline > 0.25 {
                deadline = now  // (fell far behind, e.g. suspended: don't race to catch up)
            }
        }
    }

    #if DEBUG
    /// Launched with -demo (debug builds only): into the game with no controller, for the simulator, which can't
    /// send a gamepad or keys to the app. Start through the title and file select, then Mario runs and jumps
    /// (with -carry, until frame 2250, standing still for a hand to take him out into the room at 2300).
    private static func demoInput(_ frame: Int) -> GamePad.State {
        var state = GamePad.State()
        if [300, 450, 600].contains(where: { frame >= $0 && frame < $0 + 3 }) { state.buttons = GamePad.start }
        let released = frame >= 2250 && ProcessInfo.processInfo.arguments.contains("-carry")
        if frame >= 900, !released {
            state.stickY = 80
            state.stickX = Int8(frame / 90 % 2 == 0 ? 30 : -30)
            if frame % 60 < 3 { state.buttons |= GamePad.a }
        }
        return state
    }
    
    @ObservationIgnored private var demoHandFrom: SIMD3<Float>?

    /// With -carry (and -room): a hand, as the simulator has none, that pinches Mario in the level at frame 2300,
    /// carries him out of the window to `target` (the stand-in room's counter) and lets go there
    private func demoHand(_ frame: Int, carrier: MarioCarrier, geometry: RoomGeometry,
                          to target: SIMD3<Float>?) -> [HandState] {
        guard frame >= 2290, frame < 2400, let target else { return [] }
        if frame == 2290 { demoHandFrom = carrier.marioInRoom(geometry: geometry) }
        guard let from = demoHandFrom.map({ $0 + SIMD3<Float>(0, 0.09, 0) }) else { return [] }
        var hand = HandState(tracked: true)
        let t = Float(min(max(frame - 2300, 0), 60)) / 60
        let to = target + SIMD3<Float>(0, 0.12, 0)
        hand.pinch = from + (to - from) * t
        hand.reach = hand.pinch
        hand.palm = hand.pinch - SIMD3<Float>(0, 0.1, 0)
        hand.pinching = frame >= 2300 && frame < 2370
        return [hand, HandState()]
    }
    #endif
}
