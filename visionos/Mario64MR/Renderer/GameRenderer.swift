import Metal
import MetalKit
import simd

/// Draws GameFrames as sm64ex's OpenGL renderer would (gfx_opengl.c): one pipeline per combiner and blend, depth
/// tested, decals pulled forward. Into a flat view (the game's picture, its viewport and scissor scaled to the
/// drawable), or into the room (ImmersiveRenderer: each draw placed in the room, seen from each eye).
final class GameRenderer: NSObject, MTKViewDelegate {
    /// Where it draws: a flat view, or the immersive space's layer
    struct Target {
        var colorFormat: MTLPixelFormat
        var depthFormat: MTLPixelFormat
        var room: Bool

        // (the game's colours are written as they are, as on OpenGL)
        static let flat = Target(colorFormat: .bgra8Unorm, depthFormat: .depth32Float, room: false)
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let target: Target
    let library: MTLLibrary
    private let frames: GameFrames
    private var pipelines: [UInt64: MTLRenderPipelineState] = [:]
    private var depthStates: [Int: MTLDepthStencilState] = [:]
    private struct SamplerKey: Hashable { var sampler: GameFrame.Sampler; var anisotropy: Int }
    private var samplers: [SamplerKey: MTLSamplerState] = [:]
    private let blank: MTLTexture
    /// In the room, the options': MSAA samples (the pipelines drawn with) and anisotropic filtering
    var sampleCount = 1
    var anisotropy = 1
    private var roomMeshPipelines: [Int: MTLRenderPipelineState] = [:]
    private let inFlight = DispatchSemaphore(value: 3)

    init?(device: MTLDevice, frames: GameFrames, target: Target = .flat) {
        guard let queue = device.makeCommandQueue(),
              let url = Bundle.main.url(forResource: "GameShaders", withExtension: "msl"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            print("Mario 64 MR: the game's shaders didn't compile: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
        self.frames = frames
        self.target = target
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let blank = device.makeTexture(descriptor: descriptor) else { return nil }
        let white: [UInt8] = [255, 255, 255, 255]
        blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: white, bytesPerRow: 4)
        self.blank = blank
    }

    // ---------------------------------------------------------------- A flat view

    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = target.colorFormat
        view.depthStencilPixelFormat = target.depthFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.clearDepth = 1
        view.preferredFramesPerSecond = 90
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame = frames.latest(), let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        inFlight.wait()
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        let size = SIMD2(Double(drawable.texture.width), Double(drawable.texture.height))
        encode(frame, into: encoder, target: size)
        encoder.endEncoding()
        commands.present(drawable)
        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commands.commit()
    }

    /// The frame's draws into a render pass whose target is `size` pixels, the game's window stretched over it
    /// (`worldOnly`: the level alone, no sky or HUD)
    func encode(_ frame: GameFrame, into encoder: MTLRenderCommandEncoder, target size: SIMD2<Double>,
                worldOnly: Bool = false) {
        guard let vertices = frame.vertices else { return }
        let scale = size / SIMD2(Double(frame.size.x), Double(frame.size.y))
        var number = frame.number
        encoder.setFragmentBytes(&number, length: 4, index: 0)
        encoder.setCullMode(.none)
        var state = DrawState()
        for draw in frame.draws where !worldOnly || draw.kind == .world {
            // OpenGL's rectangles count from the bottom left of the game's window, Metal's from the top left
            let v = draw.viewport
            encoder.setViewport(MTLViewport(
                originX: Double(v.x) * scale.x, originY: Double(frame.size.y - v.y - v.w) * scale.y,
                width: Double(v.z) * scale.x, height: Double(v.w) * scale.y, znear: 0, zfar: 1))
            guard let scissor = scissorRect(draw.scissor, frame: frame.size, scale: scale, target: size) else {
                continue
            }
            encoder.setScissorRect(scissor)
            guard prepare(draw, encoder: encoder, state: &state) else { continue }
            state.setVertices(vertices, from: draw, encoder: encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.vertexCount)
        }
    }

    private func scissorRect(_ s: SIMD4<Int32>, frame: SIMD2<Int32>, scale: SIMD2<Double>,
                             target: SIMD2<Double>) -> MTLScissorRect? {
        let x0 = max(0, (Double(s.x) * scale.x).rounded())
        let y0 = max(0, (Double(frame.y - s.y - s.w) * scale.y).rounded())
        let x1 = min(target.x, (Double(s.x + s.z) * scale.x).rounded())
        let y1 = min(target.y, (Double(frame.y - s.y) * scale.y).rounded())
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: Int(x0), y: Int(y0), width: Int(x1 - x0), height: Int(y1 - y0))
    }

    // ---------------------------------------------------------------- In the room

    /// What the room's shaders take for one draw (RoomDraw in GameShaders.msl)
    struct RoomDraw: Equatable {
        var roomFromClip: simd_float4x4
        var kind: SIMD4<UInt32>
    }

    /// What they take for one eye (RoomEye)
    struct RoomEye {
        var viewProjection: simd_float4x4
        var roomFromView: simd_float4x4
        var roomFromWindow: simd_float4x4
        var windowFromRoom: simd_float4x4
        var eye: SIMD4<Float>
        var window: SIMD4<Float>
        var up: SIMD4<Float>
    }

    /// The frame's draws for one eye: the game (`actors` false), or Mario out in the room (`actors` true, after the
    /// room's depth). `roomFromClip` gives each level draw's way from the game's clip space into the room, and
    /// `actorFromClip` Mario's while he's out in the room (RoomPlacement). `beforeScreen` is called after the
    /// level and before the HUD and the game's other flat pictures (it draws its own state: the frame's is set again).
    func encodeRoom(_ frame: GameFrame, into encoder: MTLRenderCommandEncoder, eye: RoomEye, actors: Bool,
                    roomFromClip: (GameFrame.Draw) -> simd_float4x4,
                    actorFromClip: (GameFrame.Draw) -> simd_float4x4,
                    beforeScreen: (() -> Void)? = nil) {
        guard let vertices = frame.vertices else { return }
        var number = frame.number
        var eye = eye
        func setFrame() {
            encoder.setFragmentBytes(&number, length: 4, index: 0)
            encoder.setFragmentBytes(&eye, length: MemoryLayout<RoomEye>.stride, index: 1)
            encoder.setVertexBytes(&eye, length: MemoryLayout<RoomEye>.stride, index: 2)
            encoder.setCullMode(.none)
        }
        setFrame()
        var before = beforeScreen
        defer { before?() }
        var state = DrawState()
        // (merged runs of a model share their projection: its matrix is worked out once a run)
        var lastProjection: simd_float4x4?, lastActor = false, lastMatrix = matrix_identity_float4x4
        for draw in frame.draws {
            if draw.kind == .screen, let call = before {
                before = nil
                call()
                setFrame()
                state = DrawState()  // (it set its own)
            }
            let actor = frame.outside(draw)
            guard actor == actors, prepare(draw, encoder: encoder, state: &state) else { continue }
            if actor || draw.kind == .world, lastProjection != draw.projection || lastActor != actor {
                lastMatrix = actor ? actorFromClip(draw) : roomFromClip(draw)
                lastProjection = draw.projection; lastActor = actor
            }
            let room = actor ? RoomDraw(roomFromClip: lastMatrix, kind: SIMD4(3, 0, 0, 0))
                : RoomDraw(roomFromClip: draw.kind == .world ? lastMatrix : matrix_identity_float4x4,
                           kind: SIMD4(draw.kind.rawValue, 0, 0, 0))
            state.setRoom(room, encoder: encoder)
            // The sky behind everything, flat pictures over it all, each with a depth the compositor shows: on the
            // headset, what's left at depth 0 (the clear, infinitely far) is taken as empty and the room shows there
            if !actor, draw.kind != .world {
                state.setDepth(overState, encoder: encoder)
            }
            state.setVertices(vertices, from: draw, encoder: encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.vertexCount)
        }
    }

    /// The level as a diorama (Diorama): only its level and Mario, from `roomFromWorld` (the game's world, units, into
    /// the room) through the game camera; cut away below `table`. No sky, no HUD.
    func encodeDiorama(_ frame: GameFrame, into encoder: MTLRenderCommandEncoder, eye: RoomEye,
                       roomFromWorld: simd_float4x4, table: Float, xScale: Float) {
        guard let vertices = frame.vertices else { return }
        var number = frame.number
        var eye = eye
        encoder.setFragmentBytes(&number, length: 4, index: 0)
        encoder.setFragmentBytes(&eye, length: MemoryLayout<RoomEye>.stride, index: 1)
        encoder.setVertexBytes(&eye, length: MemoryLayout<RoomEye>.stride, index: 2)
        encoder.setCullMode(.none)
        let roomFromView = roomFromWorld * frame.camera.inverse
        let narrowing = simd_float4x4(diagonal: SIMD4(xScale, 1, 1, 1))
        var cache: [SIMD16<Float>: simd_float4x4] = [:]
        var state = DrawState()
        for draw in frame.draws where draw.kind == .world {
            guard prepare(draw, encoder: encoder, state: &state) else { continue }
            let key = draw.projectionKey
            let m = cache[key] ?? roomFromView * (narrowing * draw.projection).inverse
            cache[key] = m
            state.setRoom(RoomDraw(roomFromClip: m, kind: SIMD4(4, table.bitPattern, 0, 0)), encoder: encoder)
            state.setVertices(vertices, from: draw, encoder: encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.vertexCount)
        }
        // See-through surfaces (lava, water) write no depth, and with no sky behind them, where nothing of the level
        // is either, they'd be left at depth 0, which the compositor takes as empty: drawn again into depth only
        for draw in frame.draws where draw.kind == .world && draw.blend && draw.depthTest {
            guard prepare(draw, encoder: encoder, state: &state, depthOnly: true),
                  let m = cache[draw.projectionKey] else { continue }
            state.setRoom(RoomDraw(roomFromClip: m, kind: SIMD4(4, table.bitPattern, 0, 0)), encoder: encoder)
            state.setVertices(vertices, from: draw, encoder: encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.vertexCount)
        }
    }

    private var roomMeshPipeline: MTLRenderPipelineState? {
        if let pipeline = roomMeshPipelines[sampleCount] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "room_mesh_vertex")
        descriptor.depthAttachmentPixelFormat = target.depthFormat
        descriptor.colorAttachments[0].pixelFormat = target.colorFormat
        descriptor.colorAttachments[0].writeMask = []
        descriptor.rasterSampleCount = sampleCount
        let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        roomMeshPipelines[sampleCount] = pipeline
        return pipeline
    }

    /// The room's surfaces (`count` vertices of packed float3, metres), into depth only
    func encodeRoomMesh(_ mesh: MTLBuffer, count: Int, into encoder: MTLRenderCommandEncoder, eye: RoomEye) {
        guard count > 0, let pipeline = roomMeshPipeline else { return }
        var eye = eye
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState(test: true, write: true))
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        encoder.setVertexBytes(&eye, length: MemoryLayout<RoomEye>.stride, index: 2)
        encoder.setVertexBuffer(mesh, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
    }

    // ---------------------------------------------------------------- Both

    /// What an encoder was last given for a draw, so that what the next draw shares with it (most of it, along a
    /// merged run of a model) isn't set again: the renderer's time goes with the number of draws, each encoded three
    /// times a frame (the window's picture, then each eye). Made afresh for each pass, and after anything else
    /// draws into the encoder.
    struct DrawState {
        fileprivate var pipelineKey: UInt64?
        fileprivate var depthState: MTLDepthStencilState?
        fileprivate var depthSet = false
        fileprivate var decal: Bool?
        fileprivate var textures: (MTLTexture?, MTLTexture?)
        fileprivate var samplers: (GameFrame.Sampler?, GameFrame.Sampler?)
        fileprivate var room: RoomDraw?
        fileprivate var vertices: MTLBuffer?

        mutating func setDepth(_ state: MTLDepthStencilState?, encoder: MTLRenderCommandEncoder) {
            guard !depthSet || state !== depthState else { return }
            encoder.setDepthStencilState(state)
            depthState = state; depthSet = true
        }

        mutating func setRoom(_ draw: RoomDraw, encoder: MTLRenderCommandEncoder) {
            guard draw != room else { return }
            var draw = draw
            encoder.setVertexBytes(&draw, length: MemoryLayout<RoomDraw>.stride, index: 1)
            encoder.setFragmentBytes(&draw, length: MemoryLayout<RoomDraw>.stride, index: 2)
            room = draw
        }

        mutating func setVertices(_ buffer: MTLBuffer, from draw: GameFrame.Draw, encoder: MTLRenderCommandEncoder) {
            if buffer === vertices {
                encoder.setVertexBufferOffset(draw.firstFloat * 4, index: 0)
            } else {
                encoder.setVertexBuffer(buffer, offset: draw.firstFloat * 4, index: 0)
                vertices = buffer
            }
        }
    }

    /// The draw's pipeline, depth, textures and samplers, those that differ from `state`'s
    /// (`depthOnly`: into depth, where it shows, and nothing else)
    private func prepare(_ draw: GameFrame.Draw, encoder: MTLRenderCommandEncoder, state: inout DrawState,
                         depthOnly: Bool = false) -> Bool {
        let key = pipelineKey(draw.shaderId, blend: draw.blend, depthOnly: depthOnly)
        if key != state.pipelineKey {
            guard let pipeline = pipeline(draw.shaderId, blend: draw.blend, depthOnly: depthOnly) else { return false }
            encoder.setRenderPipelineState(pipeline)
            state.pipelineKey = key
        }
        state.setDepth(depthState(test: draw.depthTest, write: draw.depthWrite || depthOnly), encoder: encoder)
        if draw.decal != state.decal {
            if target.room {  // (reversed depth: nearer is more)
                encoder.setDepthBias(draw.decal ? 4 : 0, slopeScale: draw.decal ? 2 : 0, clamp: 0)
            } else {
                encoder.setDepthBias(draw.decal ? -2 : 0, slopeScale: draw.decal ? -2 : 0, clamp: 0)
            }
            state.decal = draw.decal
        }
        let t0 = draw.textures.0 ?? blank, t1 = draw.textures.1 ?? blank
        if state.textures.0 !== t0 { encoder.setFragmentTexture(t0, index: 0); state.textures.0 = t0 }
        if state.textures.1 !== t1 { encoder.setFragmentTexture(t1, index: 1); state.textures.1 = t1 }
        if state.samplers.0 != draw.samplers.0 {
            encoder.setFragmentSamplerState(sampler(draw.samplers.0), index: 0); state.samplers.0 = draw.samplers.0
        }
        if state.samplers.1 != draw.samplers.1 {
            encoder.setFragmentSamplerState(sampler(draw.samplers.1), index: 1); state.samplers.1 = draw.samplers.1
        }
        return true
    }

    private func pipelineKey(_ shaderId: UInt32, blend: Bool, depthOnly: Bool) -> UInt64 {
        UInt64(shaderId) | (blend ? 1 << 32 : 0) | UInt64(sampleCount) << 33 | (depthOnly ? 1 << 48 : 0)
    }

    private func pipeline(_ shaderId: UInt32, blend: Bool, depthOnly: Bool = false) -> MTLRenderPipelineState? {
        let key = pipelineKey(shaderId, blend: blend, depthOnly: depthOnly)
        if let pipeline = pipelines[key] { return pipeline }
        do {
            let constants = MTLFunctionConstantValues()
            var id = shaderId
            constants.setConstantValue(&id, type: .uint, index: 0)
            var opaque = !blend  // (in the room, alpha is coverage over the passthrough: opaque draws cover it)
            constants.setConstantValue(&opaque, type: .bool, index: 1)
            var depthOnly = depthOnly
            constants.setConstantValue(&depthOnly, type: .bool, index: 2)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try library.makeFunction(
                name: target.room ? "game_vertex_room" : "game_vertex", constantValues: constants)
            descriptor.fragmentFunction = try library.makeFunction(
                name: target.room ? "game_fragment_room" : "game_fragment", constantValues: constants)
            descriptor.depthAttachmentPixelFormat = target.depthFormat
            descriptor.rasterSampleCount = sampleCount
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = target.colorFormat
            if depthOnly { color.writeMask = [] }
            if blend && !depthOnly {  // glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                // (in the room, alpha is coverage over the passthrough: blended over, it only grows)
                color.sourceAlphaBlendFactor = target.room ? .one : .sourceAlpha
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch {
            print("Mario 64 MR: shader \(String(shaderId, radix: 16)) didn't build: \(error)")
            return nil
        }
    }

    /// Drawn over whatever is there, writing its depth (the room's sky and flat pictures)
    private lazy var overState: MTLDepthStencilState? = {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: descriptor)
    }()

    private func depthState(test: Bool, write: Bool) -> MTLDepthStencilState? {
        // OpenGL writes no depth while the test is off
        let key = (test ? 1 : 0) | (write && test ? 2 : 0)
        if let state = depthStates[key] { return state }
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = !test ? .always : target.room ? .greaterEqual : .lessEqual
        descriptor.isDepthWriteEnabled = write && test
        let state = device.makeDepthStencilState(descriptor: descriptor)
        depthStates[key] = state
        return state
    }

    private func sampler(_ s: GameFrame.Sampler) -> MTLSamplerState? {
        let key = SamplerKey(sampler: s, anisotropy: s.linear ? anisotropy : 1)
        if let state = samplers[key] { return state }
        func address(_ mode: Int32) -> MTLSamplerAddressMode {
            mode & 2 != 0 ? .clampToEdge : mode & 1 != 0 ? .mirrorRepeat : .repeat
        }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = s.linear ? .linear : .nearest
        descriptor.magFilter = s.linear ? .linear : .nearest
        descriptor.sAddressMode = address(s.wrapS)
        descriptor.tAddressMode = address(s.wrapT)
        // (textures with mipmaps, the options' Textures: the mipmaps, and anisotropy; none have only the one)
        descriptor.mipFilter = s.linear ? .linear : .notMipmapped
        descriptor.maxAnisotropy = key.anisotropy
        let state = device.makeSamplerState(descriptor: descriptor)
        samplers[key] = state
        return state
    }
}

private extension GameFrame.Draw {
    /// The draw's projection, as a key: draws through the same one share its unprojection
    var projectionKey: SIMD16<Float> {
        let c = projection.columns
        return SIMD16(lowHalf: SIMD8(lowHalf: c.0, highHalf: c.1), highHalf: SIMD8(lowHalf: c.2, highHalf: c.3))
    }
}
