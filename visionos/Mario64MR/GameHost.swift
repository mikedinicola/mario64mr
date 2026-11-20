import Foundation
import Metal
import Observation
import simd

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
    /// The options' Hands: Mario's gloves over your hands in the room (the room's scene then hides your own under
    /// what it draws)
    private(set) var gloves = GameOptions.savedGraphics.gloves

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
        // Saves in the app's Documents folder, which stays when the app is rebuilt
        let saves = URL.documentsDirectory.appendingPathComponent("sm64")
        try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)

        // The other two libraries load with the app (linked); touch each once to show they're there
        let slots = gd_api_texture_slot_count()
        var marioTexture = "no ROM"
        let rom = try? Data(contentsOf: resources.appendingPathComponent("baserom.us.z64"))
        if let rom {
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
        // The options menu's values, as you left them; the room applies the graphics
        let options = GameOptions()
        var graphics = options.graphics
        self.room.update { [graphics] in $0.graphics = graphics }
        maker.mipmaps = graphics.mipmaps
        publish { [gloves = graphics.gloves] in $0.gloves = gloves }
        // The title screen's face in the room (libgoddard), and its sounds (libsm64)
        let title = TitleScreen(device: device, pack: gameData.appendingPathComponent("res/base.zip"), rom: rom)
        if title == nil { print("Mario 64 MR: the title screen's face didn't start") }
        let titleHands = TitleHands()
        var titleFrame: TitleFrame?
        var startFrames = 0
        var wasPinching = [false, false]

        #if DEBUG
        let demo = ProcessInfo.processInfo.arguments.contains("-demo")
        let carryDemo = ProcessInfo.processInfo.arguments.contains("-carry")
        let cartDemo = ProcessInfo.processInfo.arguments.contains("-cart")
        #endif
        let carrier = MarioCarrier()
        let padReader = PadReader()
        let controllerTilt = ControllerTilt()
        let period = 1.0 / 30
        var deadline = Date.now.timeIntervalSinceReferenceDate
        var frame = 0
        let perf = PerfLog(name: "game")
        var joining = true
        var mario128 = false  // (begun in the game: sm64unity_stage_room_begin)
        while !Thread.current.isCancelled {
            // (-perfab: the frame's batches joined, then not, 10 s each, to compare in the console's lines)
            if PerfLog.compare, frame % 300 == 0 {
                joining = frame % 600 == 0
                sm64unity_join_batches(joining ? 1 : 0)
            }
            var pad = padReader.read(busy: self.room.current.busy)
            #if DEBUG
            if demo { pad = Self.demoInput(frame) }
            #endif
            // In the room: the level unculled (it's seen from your eyes, not the game camera), billboards facing you
            let room = self.room.current
            // Shut in its cartridge, the game waits (unless Mario's out in the room)
            if room.on, let geometry = room.geometry, !geometry.open, sm64unity_carry_mode() < 2 {
                carrier.reset()
                titleHands.reset()
                sleep(until: &deadline, period: period)
                continue
            }
            sm64unity_mr_geometry(room.on ? 1 : 0)
            // The treasure chest by the window: the game's own, drawn by the game where the room has it
            if room.on, let c = room.chest {
                sm64unity_chest(1, c.at.x, c.at.y, c.at.z, c.yaw, c.lid, c.scale)
            } else {
                sm64unity_chest(0, 0, 0, 0, 0, 0, 1)
            }
            // (a diorama is seen whole: nothing left out for being far from Mario)
            sm64unity_draw_far(room.on && room.geometry?.diorama == true ? 1 : 0)
            if let triangles = room.roomTriangles {  // (the room, for Mario out in it)
                self.room.update { $0.roomTriangles = nil }
                let loaded = triangles.withUnsafeBufferPointer { sm64unity_room_mesh($0.baseAddress, Int32($0.count / 9)) }
                if loaded < 0 { print("Mario 64 MR: the room didn't load (\(loaded))") }
                carrier.roomHasSurfaces = loaded > 0
            }
            // Mario 128 in your room: begun once the room's open for it, put down where the room says, ended with it
            if room.on, room.mario128, !mario128 { mario128 = sm64unity_stage_room_begin() == 1 }
            if mario128, !(room.on && room.mario128) {
                sm64unity_stage_room_end()
                mario128 = false
            }
            if let place = room.stagePlace, mario128, sm64unity_stage_room() == 1 {
                self.room.update { $0.stagePlace = nil }
                let loaded = place.triangles.withUnsafeBufferPointer {
                    sm64unity_stage_room_place($0.baseAddress, Int32($0.count / 9), place.marioY)
                }
                if loaded < 0 { print("Mario 64 MR: Mario 128's room didn't load (\(loaded))") }
            }
            let (stageRoom, stageCount) = (sm64unity_stage_room(), sm64unity_stage_count())
            self.room.update { $0.stageRoom = stageRoom; $0.stageCount = stageCount }
            // Your hands and Mario
            if room.mario128 {
                carrier.reset()  // (no window to take him through: the room holds him, Mario128Stage)
            } else if room.on, let geometry = room.geometry, !geometry.diorama {
                var hands = room.hands
                #if DEBUG
                if demo, carryDemo { hands = demoHand(frame, carrier: carrier, geometry: geometry, to: room.debugRelease) }
                #endif
                let picks = room.picks
                if !picks.isEmpty { self.room.update { $0.picks.removeFirst(min(picks.count, $0.picks.count)) } }
                carrier.update(hands: hands, geometry: geometry, picks: picks)
            } else if room.on, let geometry = room.geometry, geometry.diorama {
                let picks = room.picks
                if !picks.isEmpty { self.room.update { $0.picks.removeFirst(min(picks.count, $0.picks.count)) } }
                carrier.touchDiorama(hands: room.hands, geometry: geometry, picks: picks)
            } else {
                carrier.reset()
            }
            // The title screen in the room: the face, your hands on it, "PRESS START"; the menus: your hand's
            // cursor and pinch (A); anywhere, a pinch with the palm up is Start
            let stage = sm64unity_stage()
            let hands = room.on ? room.hands : []
            #if DEBUG
            if cartDemo, stage == 2 || stage == 4, frame % 90 < 3 { pad.buttons |= GamePad.start }
            #endif
            let spawnable = stage == 3 ? sm64unity_spawn_available() : 0
            self.room.update { $0.stage = stage; $0.spawnable = spawnable }
            // A diorama: the stick moves Mario the way you look (not the way the game camera does)
            if room.on, let forward = room.dioramaForward {
                Self.turnStick(&pad, toward: forward)
                // (and the camera stick turns and zooms the diorama, not the game camera: Diorama.update)
                pad.buttons &= ~(GamePad.cUp | GamePad.cDown | GamePad.cLeft | GamePad.cRight)
            }
            if let geometry = room.geometry, room.on, geometry.open, stage == 1, let title {
                // (your head, from the game camera's view space into the window's)
                let eye = room.head.map { geometry.inWindow(geometry.roomFromView.transform($0)) }
                let (cursors, start) = titleHands.update(hands: hands, geometry: geometry, frame: titleFrame, eye: eye)
                if start { startFrames = 3 }
                titleFrame = title.tick(cursors, pad: pad)
            } else {
                titleHands.reset()
                titleFrame = nil
            }
            if let geometry = room.geometry, room.on, geometry.open, stage == 2 || stage == 4,
               let pointing = Self.menuCursor(hands, geometry: geometry) {
                sm64unity_cursor(stage == 2 ? 1 : 0, pointing.x, pointing.y)
                if pointing.pinching { pad.buttons |= GamePad.a }
            } else {
                sm64unity_cursor(0, 0, 0)
            }
            for i in hands.indices where i < 2 {
                let pinching = hands[i].tracked && hands[i].pinching
                if pinching, !wasPinching[i], hands[i].palmUp, !hands[i].controller { startFrames = 3 }
                wasPinching[i] = pinching
            }
            if startFrames > 0 { pad.buttons |= GamePad.start; startFrames -= 1 }
            if let title { title.audio(queued: audio.effectsBuffered) { audio.pushEffects($0, count: $1) } }
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
            // The disc stage tilts as you lean the controller, while it's on (D-pad up): as the stick, the way you
            // look in a diorama
            var tilt = controllerTilt.read(on: sm64unity_stage_tilting() == 1)
            if room.on, let forward = room.dioramaForward { tilt = Self.turned(tilt, toward: forward) ?? tilt }
            sm64unity_stage_tilt(tilt.y, tilt.x)
            let tickStart = PerfLog.now
            guard sm64unity_tick(pad.buttons, pad.stickX, pad.stickY) == 1 else {
                return fail("The game stopped (bridge error \(sm64unity_error()))")
            }
            if options.sync() { carrier.bringBack(geometry: room.geometry) }
            if options.graphics != graphics {
                graphics = options.graphics
                self.room.update { [graphics] in $0.graphics = graphics }
                maker.mipmaps = graphics.mipmaps
                publish { [gloves = graphics.gloves] in $0.gloves = gloves }
            }
            var count: Int32 = 0
            if let samples = sm64unity_audio(&count), count > 0 {
                audio.push(samples, count: Int(count))
            }
            // 60 fps build: the tick drew the frame between the last tick and this one, shown now; render_current
            // draws this tick's own, shown half a tick later
            let tickEnd = PerfLog.now
            perf.add("step + between frame", tickEnd - tickStart)
            var between = maker.make()
            between.title = titleFrame
            perf.add("handoff", PerfLog.now - tickEnd)
            var marioState = [Float](repeating: 0, count: 8)
            if sm64unity_mario(&marioState) != 0, sm64unity_carry_mode() < 2 {
                between.mario = SIMD3(marioState[0], marioState[1], marioState[2])
            }
            let currentStart = PerfLog.now
            if sm64unity_interpolates() == 1, sm64unity_render_current() == 1 {
                perf.add("current frame", PerfLog.now - currentStart)
                let handoff = PerfLog.now
                var current = maker.make()
                perf.add("handoff", PerfLog.now - handoff)
                current.title = titleFrame
                current.mario = between.mario
                output.publish(between, then: current, after: period / 2)
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
            perf.add("busy", PerfLog.now - tickStart)
            if PerfLog.now > deadline + period { perf.count("late") }
            perf.step(extra: "\(between.draws.count) batches, \((between.vertices?.length ?? 0) / 4000)k floats"
                      + (PerfLog.compare ? ", joining \(joining ? "on" : "off")" : ""))
            sleep(until: &deadline, period: period)
        }
    }

    private func sleep(until deadline: inout TimeInterval, period: TimeInterval) {
        deadline += period
        let now = Date.now.timeIntervalSinceReferenceDate
        if deadline > now {
            Thread.sleep(forTimeInterval: deadline - now)
        } else if now - deadline > 0.25 {
            deadline = now  // (fell far behind, e.g. suspended: don't race to catch up)
        }
    }

    /// The stick turned from your forward (in the game's world) to the game camera's: pushed up, Mario runs the way
    /// you look
    private static func turnStick(_ pad: inout GamePad.State, toward forward: SIMD3<Float>) {
        guard pad.stickX != 0 || pad.stickY != 0,
              let v = turned(SIMD2(Float(pad.stickX), Float(pad.stickY)), toward: forward) else { return }
        pad.stickX = Int8(max(-128, min(127, v.x.rounded())))
        pad.stickY = Int8(max(-128, min(127, v.y.rounded())))
    }

    /// A stick's way (x right, y forward) as you look along `forward`, turned to the game camera's (what the game
    /// reads a stick as). Nil without a camera
    private static func turned(_ v: SIMD2<Float>, toward forward: SIMD3<Float>) -> SIMD2<Float>? {
        guard let m = sm64unity_camera() else { return nil }
        var cameraForward = -SIMD3(m[2], m[6], m[10])  // (the view matrix's third row, as simd reads it)
        cameraForward.y = 0
        guard simd_length(cameraForward) > 1e-4 else { return nil }
        cameraForward = simd_normalize(cameraForward)
        let up = SIMD3<Float>(0, 1, 0)
        let cameraRight = simd_cross(cameraForward, up), lookRight = simd_cross(forward, up)
        let wanted = lookRight * v.x + forward * v.y
        return SIMD2(simd_dot(wanted, cameraRight), simd_dot(wanted, cameraForward))
    }

    /// A hand at the window, for the menus' cursor: where it points in the game's 320×240 screen (its 4:3 middle
    /// in the window's plane), and whether it pinches
    private static func menuCursor(_ hands: [HandState], geometry g: RoomGeometry)
        -> (x: Float, y: Float, pinching: Bool)? {
        let h = g.halfSize
        for hand in hands.reversed() where hand.tracked {  // (the right hand first)
            let p = g.inWindow(hand.pinch)
            guard abs(p.x) < h.y * 4 / 3 * 1.1, abs(p.y) < h.y * 1.1, p.z > -0.2, p.z < 0.25 else { continue }
            return (160 + p.x / (h.y * 4 / 3) * 160, 120 - p.y / h.y * 120, hand.pinching)
        }
        return nil
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

/// Timings, for the console, with -perf in the run's arguments (-perfab too: the game thread then joins a frame's
/// batches for 10 s and doesn't for 10 s, by turns, to compare): once a second, a line of each part's mean time a step
/// (or a frame) in milliseconds. One for each thread that keeps one (the game's, the room's renderer); `add` and
/// `count` from that thread, `addAnyThread` from any (the GPU's times, as command buffers complete).
final class PerfLog: @unchecked Sendable {
    static let enabled = ProcessInfo.processInfo.arguments.contains { $0 == "-perf" || $0 == "-perfab" }
    static let compare = ProcessInfo.processInfo.arguments.contains("-perfab")
    static var now: Double { ProcessInfo.processInfo.systemUptime }

    private let name: String
    private var sums: [(String, Double)] = [], counts: [(String, Int)] = []
    private var steps = 0, since = PerfLog.now
    private let lock = NSLock()
    private var other: [(String, Double)] = []

    init(name: String) { self.name = name }

    func add(_ part: String, _ seconds: Double) {
        guard Self.enabled else { return }
        if let i = sums.firstIndex(where: { $0.0 == part }) { sums[i].1 += seconds } else { sums.append((part, seconds)) }
    }
    func count(_ what: String) {
        guard Self.enabled else { return }
        if let i = counts.firstIndex(where: { $0.0 == what }) { counts[i].1 += 1 } else { counts.append((what, 1)) }
    }
    func addAnyThread(_ part: String, _ seconds: Double) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        if let i = other.firstIndex(where: { $0.0 == part }) { other[i].1 += seconds } else { other.append((part, seconds)) }
    }

    /// The end of a step (or frame): a line once a second
    func step(extra: String = "") {
        guard Self.enabled else { return }
        steps += 1
        let elapsed = Self.now - since
        guard elapsed >= 1 else { return }
        lock.lock(); let fromOthers = other; other = []; lock.unlock()
        var line = String(format: "PERF %@ %.1f/s", name, Double(steps) / elapsed)
        for (part, total) in sums + fromOthers { line += String(format: " · %@ %.2f ms", part, total * 1000 / Double(steps)) }
        for (what, n) in counts { line += " · \(what) \(n)" }
        if !extra.isEmpty { line += " · " + extra }
        fputs(line + "\n", stderr)  // (unbuffered: in Xcode's console as it comes)
        sums = []; counts = []; steps = 0; since = Self.now
    }
}

