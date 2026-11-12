import Metal
import os
import simd

/// One frame of the game's draw calls, copied out of SM64Game on the game thread so the renderer can draw it while
/// the game goes on to the next one.
struct GameFrame {
    struct Draw {
        var shaderId: UInt32
        var firstFloat: Int
        var vertexCount: Int
        var floatsPerVertex: Int
        var textures: (MTLTexture?, MTLTexture?)
        var samplers: (Sampler, Sampler)
        var depthTest, depthWrite, decal, blend: Bool
        var viewport: SIMD4<Int32>  // x, y, width, height in the game's window, OpenGL's origin at the bottom left
        var scissor: SIMD4<Int32>
        var kind: Kind
        /// What it is (unity_set_tag): 0 the level, 1 Mario, 2 Mario's shadow, 3 the HUD
        var tag: Int32
        /// The projection the game drew it with (as simd reads the game's row-vector matrix: clip = projection * v)
        var projection: simd_float4x4
    }

    /// What a draw is, for drawing it in the room (ImmersiveRenderer)
    enum Kind: UInt32 {
        case world = 0   // the level, in perspective
        case sky = 1     // the sky (orthographic, before the level)
        case screen = 2  // the HUD (tag 3), dialogs, menus, fades (orthographic, after the level)
    }

    /// Filtering and wrapping as sm64ex's set_sampler_parameters gets them (G_TX_MIRROR 1, G_TX_CLAMP 2)
    struct Sampler: Hashable {
        var linear: Bool
        var wrapS, wrapT: Int32
    }

    var vertices: MTLBuffer?
    var draws: [Draw]
    /// The game camera (world to view, as simd reads it) of the frame
    var camera: simd_float4x4
    /// Mario out in the room (sm64unity_carry_mode 2 or 3): his draws are then in the room's game coordinates
    var marioOutside: Bool
    var size: SIMD2<Int32>  // the window the game draws for (1280×720 in the 60 fps build)
    var number: UInt32
    /// The title screen's face (TitleScreen), drawn in the window in place of the game's own title
    var title: TitleFrame? = nil
    /// Mario in the level (game units), when he's there (for the diorama to follow)
    var mario: SIMD3<Float>? = nil
}

extension GameFrame {
    /// The middle of the level (x, z, game units): of its drawn vertices' bounds, each taken back from the game's
    /// clip space through its projection and the game camera into the world. (In the room the level is drawn whole,
    /// unculled: sm64unity_mr_geometry.)
    func levelCenter() -> SIMD2<Float>? {
        guard let vertices else { return nil }
        let floats = vertices.contents().bindMemory(to: Float.self, capacity: vertices.length / 4)
        let worldFromView = camera.inverse
        var low = SIMD2<Float>(repeating: .infinity), high = -low
        for draw in draws where draw.kind == .world && draw.tag == 0 && draw.floatsPerVertex >= 4 {
            let worldFromClip = worldFromView * draw.projection.inverse
            for i in 0..<draw.vertexCount {
                let v = floats + draw.firstFloat + i * draw.floatsPerVertex
                let world = worldFromClip * SIMD4(v[0], v[1], v[2], v[3])
                guard abs(world.w) > 1e-6 else { continue }
                let p = SIMD2(world.x, world.z) / world.w
                low = simd_min(low, p); high = simd_max(high, p)
            }
        }
        return low.x <= high.x ? (low + high) / 2 : nil
    }
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
            let projections = sm64unity_projections(), tags = sm64unity_tags()
            var levelDrawn = false
            for (i, b) in UnsafeBufferPointer(start: batches, count: Int(batchCount)).enumerated()
            where b.triangle_count > 0 {
                let projection = projections.map { matrix($0 + i * 16) } ?? matrix_identity_float4x4
                let orthographic = projection.columns.2.w == 0  // (guPerspective's -1 there, guOrtho's 0)
                let kind: GameFrame.Kind = tags?[i] == 3 ? .screen : !orthographic ? .world : levelDrawn ? .screen : .sky
                levelDrawn = levelDrawn || kind == .world
                draws.append(GameFrame.Draw(
                    shaderId: b.shader_id,
                    firstFloat: Int(b.first_float),
                    vertexCount: Int(b.triangle_count) * 3,
                    floatsPerVertex: Int(b.float_count) / (Int(b.triangle_count) * 3),
                    textures: (texture(b.texture0), texture(b.texture1)),
                    samplers: (GameFrame.Sampler(linear: b.filter0 != 0, wrapS: b.wraps0, wrapT: b.wrapt0),
                               GameFrame.Sampler(linear: b.filter1 != 0, wrapS: b.wraps1, wrapT: b.wrapt1)),
                    depthTest: b.depth_test != 0, depthWrite: b.depth_write != 0,
                    decal: b.decal != 0, blend: b.blend != 0,
                    viewport: SIMD4(b.viewport.0, b.viewport.1, b.viewport.2, b.viewport.3),
                    scissor: SIMD4(b.scissor.0, b.scissor.1, b.scissor.2, b.scissor.3),
                    kind: kind, tag: tags?[i] ?? 0, projection: projection))
            }
        }
        number &+= 1
        let size = sm64unity_interpolates() == 1 ? SIMD2<Int32>(1280, 720) : SIMD2<Int32>(320, 240)
        let camera = sm64unity_camera().map { matrix($0) } ?? matrix_identity_float4x4
        return GameFrame(vertices: buffer, draws: draws, camera: camera, marioOutside: sm64unity_carry_mode() >= 2,
                         size: size, number: number)
    }

    /// The game's Mat4 (row vectors: v' = v * M) as simd's column-major matrix, which is then M transposed:
    /// v' = matrix * v
    private func matrix(_ m: UnsafePointer<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                      SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
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
