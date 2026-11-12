import AVFAudio
import os

/// The game's sound: interleaved stereo s16 at 32 kHz (sm64ex's US audio: 2 × 544 or 528 frames a game frame),
/// queued from the game thread and played by AVAudioEngine. The game reads back how much is queued
/// (sm64unity_audio_buffered) and makes a little more or less each frame to keep it near 1100 frames.
final class AudioOutput {
    static let sampleRate = 32000.0
    private static let capacity = 16384  // frames (half a second): more than that queued and the oldest is dropped

    private let engine = AVAudioEngine()
    private let lock = OSAllocatedUnfairLock()
    private var ring = [Int16](repeating: 0, count: AudioOutput.capacity * 2)
    private var readIndex = 0  // in frames
    private var queued = 0     // frames
    // A second stream mixed in: the title screen's sounds (libsm64's audio)
    private var effects = [Int16](repeating: 0, count: AudioOutput.capacity * 2)
    private var effectsRead = 0
    private var effectsQueued = 0

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            self.pull(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    func start() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            print("Audio didn't start: \(error)")
        }
    }

    /// Frames queued and not yet played.
    var buffered: Int { lock.withLock { queued } }

    /// Frames of the second stream queued and not yet played.
    var effectsBuffered: Int { lock.withLock { effectsQueued } }

    /// Queues interleaved stereo samples of the second stream, mixed into the game's as they play
    func pushEffects(_ samples: UnsafePointer<Int16>, count: Int) {
        let frames = count / 2, capacity = Self.capacity
        guard frames > 0 else { return }
        lock.withLock {
            let overflow = effectsQueued + frames - capacity
            if overflow > 0 {
                effectsRead = (effectsRead + overflow) % capacity
                effectsQueued -= overflow
            }
            var write = (effectsRead + effectsQueued) % capacity
            for frame in 0..<frames {
                effects[write * 2] = samples[frame * 2]
                effects[write * 2 + 1] = samples[frame * 2 + 1]
                write = (write + 1) % capacity
            }
            effectsQueued += frames
        }
    }

    /// Queues interleaved stereo samples (count is samples, two a frame).
    func push(_ samples: UnsafePointer<Int16>, count: Int) {
        let frames = count / 2
        guard frames > 0 else { return }
        let capacity = Self.capacity
        lock.withLock {
            let overflow = queued + frames - capacity
            if overflow > 0 {
                readIndex = (readIndex + overflow) % capacity
                queued -= overflow
            }
            var write = (readIndex + queued) % capacity
            for frame in 0..<frames {
                ring[write * 2] = samples[frame * 2]
                ring[write * 2 + 1] = samples[frame * 2 + 1]
                write = (write + 1) % capacity
            }
            queued += frames
        }
    }

    private func pull(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        let capacity = Self.capacity
        lock.withLock {
            let available = min(frames, queued)
            for frame in 0..<available {
                let index = (readIndex + frame) % capacity
                left[frame] = Float(ring[index * 2]) / 32768
                right[frame] = Float(ring[index * 2 + 1]) / 32768
            }
            for frame in available..<frames {  // (ran dry: silence until the game catches up)
                left[frame] = 0
                right[frame] = 0
            }
            readIndex = (readIndex + available) % capacity
            queued -= available
            let mixed = min(frames, effectsQueued)
            for frame in 0..<mixed {
                let index = (effectsRead + frame) % capacity
                left[frame] = max(-1, min(1, left[frame] + Float(effects[index * 2]) / 32768))
                right[frame] = max(-1, min(1, right[frame] + Float(effects[index * 2 + 1]) / 32768))
            }
            effectsRead = (effectsRead + mixed) % capacity
            effectsQueued -= mixed
        }
    }
}
