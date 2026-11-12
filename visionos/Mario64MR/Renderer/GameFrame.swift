import Metal
import os

/// One frame of the game's draw calls, copied out of SM64Game on the game thread so the renderer can draw it while
/// the game goes on to the next one.
struct GameFrame {
    struct Draw {
        var shaderId: UInt32
        var firstFloat: Int
        var vertexCount: Int
        var textures: (MTLTexture?, MTLTexture?)
        var samplers: (Sampler, Sampler)
        var depthTest, depthWrite, decal, blend: Bool
        var viewport: SIMD4<Int32>  // x, y, width, height in the game's window, OpenGL's origin at the bottom left
        var scissor: SIMD4<Int32>
    }

    /// Filtering and wrapping as sm64ex's set_sampler_parameters gets them (G_TX_MIRROR 1, G_TX_CLAMP 2)
    struct Sampler: Hashable {
        var linear: Bool
        var wrapS, wrapT: Int32
    }

    var vertices: MTLBuffer?
    var draws: [Draw]
    var size: SIMD2<Int32>  // the window the game draws for (1280×720 in the 60 fps build)
    var number: UInt32
}

/// Makes GameFrames from the game's output. Game thread only. The game's textures become Metal textures once per
/// version; a new version gets a new texture, so a frame still being drawn keeps the one it was made with.
final class GameFrameMaker {
    private let device: MTLDevice
    private var textures: [UInt32: (version: Int32, texture: MTLTexture)] = [:]
    private var number: UInt32 = 0

    init(device: MTLDevice) { self.device = device }

    func make() -> GameFrame {
        var floatCount: Int32 = 0
        var buffer: MTLBuffer?
        if let floats = sm64unity_vertices(&floatCount), floatCount > 0 {
            buffer = device.makeBuffer(bytes: floats, length: Int(floatCount) * 4, options: .storageModeShared)
        }
        var batchCount: Int32 = 0
        var draws: [GameFrame.Draw] = []
        if let batches = sm64unity_batches(&batchCount), buffer != nil {
            draws.reserveCapacity(Int(batchCount))
            for b in UnsafeBufferPointer(start: batches, count: Int(batchCount)) where b.triangle_count > 0 {
                draws.append(GameFrame.Draw(
                    shaderId: b.shader_id,
                    firstFloat: Int(b.first_float),
                    vertexCount: Int(b.triangle_count) * 3,
                    textures: (texture(b.texture0), texture(b.texture1)),
                    samplers: (GameFrame.Sampler(linear: b.filter0 != 0, wrapS: b.wraps0, wrapT: b.wrapt0),
                               GameFrame.Sampler(linear: b.filter1 != 0, wrapS: b.wraps1, wrapT: b.wrapt1)),
                    depthTest: b.depth_test != 0, depthWrite: b.depth_write != 0,
                    decal: b.decal != 0, blend: b.blend != 0,
                    viewport: SIMD4(b.viewport.0, b.viewport.1, b.viewport.2, b.viewport.3),
                    scissor: SIMD4(b.scissor.0, b.scissor.1, b.scissor.2, b.scissor.3)))
            }
        }
        number &+= 1
        let size = sm64unity_interpolates() == 1 ? SIMD2<Int32>(1280, 720) : SIMD2<Int32>(320, 240)
        return GameFrame(vertices: buffer, draws: draws, size: size, number: number)
    }

    private func texture(_ id: UInt32) -> MTLTexture? {
        guard id != 0 else { return nil }
        var width: Int32 = 0, height: Int32 = 0, version: Int32 = 0
        guard let pixels = sm64unity_texture(Int32(id), &width, &height, &version), width > 0, height > 0 else {
            return nil
        }
        if let cached = textures[id], cached.version == version { return cached.texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: Int(width), height: Int(height), mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, Int(width), Int(height)), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: Int(width) * 4)
        textures[id] = (version, texture)
        return texture
    }
}

/// The frames handed from the game thread to the renderer. In the 60 fps build each game tick gives two: the frame
/// between the last tick and this one, shown now, and this tick's own, shown half a tick later.
final class GameFrames: @unchecked Sendable {
    private struct State {
        var current: GameFrame?
        var next: (frame: GameFrame, at: TimeInterval)?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    func publish(_ frame: GameFrame, then next: GameFrame? = nil, after delay: TimeInterval = 0) {
        let at = Date.now.timeIntervalSinceReferenceDate + delay
        state.withLockUnchecked { $0.current = frame; $0.next = next.map { ($0, at) } }
    }

    /// The newest frame due by now
    func latest() -> GameFrame? {
        let now = Date.now.timeIntervalSinceReferenceDate
        return state.withLockUnchecked { state in
            if let next = state.next, next.at <= now { state.current = next.frame; state.next = nil }
            return state.current
        }
    }
}
