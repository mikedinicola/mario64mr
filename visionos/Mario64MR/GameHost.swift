import Foundation
import Observation

/// Runs the game (SM64Game) on a thread of its own at 30 game frames a second: the pad in, the frame's sound out to
/// AudioOutput. Phase 0: nothing is drawn yet; the frame's batches are only counted.
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

        let period = 1.0 / 30
        var deadline = Date.now.timeIntervalSinceReferenceDate
        var frame = 0
        while !Thread.current.isCancelled {
            let pad = GamePad.read()
            sm64unity_audio_buffered(Int32(audio.buffered))
            guard sm64unity_tick(pad.buttons, pad.stickX, pad.stickY) == 1 else {
                return fail("The game stopped (bridge error \(sm64unity_error()))")
            }
            var count: Int32 = 0
            if let samples = sm64unity_audio(&count), count > 0 {
                audio.push(samples, count: Int(count))
            }
            // 60 fps build: the tick drew the in-between frame, this draws the frame itself
            if sm64unity_interpolates() == 1 {
                _ = sm64unity_render_current()
            }
            var batchCount: Int32 = 0
            _ = sm64unity_batches(&batchCount)
            frame += 1
            if frame % 15 == 0 {
                let (stage, batches, queued) = (Int(sm64unity_stage()), Int(batchCount), audio.buffered)
                publish { $0.frames = frame; $0.stage = stage; $0.batches = batches; $0.queuedAudio = queued }
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
}
