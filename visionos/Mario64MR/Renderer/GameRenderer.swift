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
    private let library: MTLLibrary
    private let frames: GameFrames
    private var pipelines: [UInt64: MTLRenderPipelineState] = [:]
    private var depthStates: [Int: MTLDepthStencilState] = [:]
    private var samplers: [GameFrame.Sampler: MTLSamplerState] = [:]
    private let blank: MTLTexture
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
    func encode(_ frame: GameFrame, into encoder: MTLRenderCommandEncoder, target size: SIMD2<Double>) {
        guard let vertices = frame.vertices else { return }
        let scale = size / SIMD2(Double(frame.size.x), Double(frame.size.y))
        var number = frame.number
        encoder.setFragmentBytes(&number, length: 4, index: 0)
        encoder.setCullMode(.none)
        for draw in frame.draws {
            // OpenGL's rectangles count from the bottom left of the game's window, Metal's from the top left
            let v = draw.viewport
            encoder.setViewport(MTLViewport(
                originX: Double(v.x) * scale.x, originY: Double(frame.size.y - v.y - v.w) * scale.y,
                width: Double(v.z) * scale.x, height: Double(v.w) * scale.y, znear: 0, zfar: 1))
            guard let scissor = scissorRect(draw.scissor, frame: frame.size, scale: scale, target: size) else {
                continue
            }
            encoder.setScissorRect(scissor)
            guard prepare(draw, encoder: encoder) else { continue }
            encoder.setVertexBuffer(vertices, offset: draw.firstFloat * 4, index: 0)
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
    struct RoomDraw {
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

    /// The frame's draws for one eye. `roomFromClip` gives each level draw's way from the game's clip space into
    /// the room (RoomPlacement).
    func encodeRoom(_ frame: GameFrame, into encoder: MTLRenderCommandEncoder, eye: RoomEye,
                    roomFromClip: (GameFrame.Draw) -> simd_float4x4) {
        guard let vertices = frame.vertices else { return }
        var number = frame.number
        var eye = eye
        encoder.setFragmentBytes(&number, length: 4, index: 0)
        encoder.setFragmentBytes(&eye, length: MemoryLayout<RoomEye>.stride, index: 1)
        encoder.setVertexBytes(&eye, length: MemoryLayout<RoomEye>.stride, index: 2)
        encoder.setCullMode(.none)
        for draw in frame.draws {
            guard prepare(draw, encoder: encoder) else { continue }
            var room = RoomDraw(roomFromClip: draw.kind == .world ? roomFromClip(draw) : matrix_identity_float4x4,
                                kind: SIMD4(draw.kind.rawValue, 0, 0, 0))
            encoder.setVertexBytes(&room, length: MemoryLayout<RoomDraw>.stride, index: 1)
            encoder.setFragmentBytes(&room, length: MemoryLayout<RoomDraw>.stride, index: 2)
            // The sky behind everything, flat pictures over it all, each with a depth the compositor shows: on the
            // headset, what's left at depth 0 (the clear, infinitely far) is taken as empty and the room shows there
            if draw.kind != .world {
                encoder.setDepthStencilState(overState)
            }
            encoder.setVertexBuffer(vertices, offset: draw.firstFloat * 4, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: draw.vertexCount)
        }
    }

    // ---------------------------------------------------------------- Both

    /// The draw's pipeline, depth, textures and samplers
    private func prepare(_ draw: GameFrame.Draw, encoder: MTLRenderCommandEncoder) -> Bool {
        guard let pipeline = pipeline(draw.shaderId, blend: draw.blend) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState(test: draw.depthTest, write: draw.depthWrite))
        if target.room {  // (reversed depth: nearer is more)
            encoder.setDepthBias(draw.decal ? 4 : 0, slopeScale: draw.decal ? 2 : 0, clamp: 0)
        } else {
            encoder.setDepthBias(draw.decal ? -2 : 0, slopeScale: draw.decal ? -2 : 0, clamp: 0)
        }
        encoder.setFragmentTexture(draw.textures.0 ?? blank, index: 0)
        encoder.setFragmentTexture(draw.textures.1 ?? blank, index: 1)
        encoder.setFragmentSamplerState(sampler(draw.samplers.0), index: 0)
        encoder.setFragmentSamplerState(sampler(draw.samplers.1), index: 1)
        return true
    }

    private func pipeline(_ shaderId: UInt32, blend: Bool) -> MTLRenderPipelineState? {
        let key = UInt64(shaderId) | (blend ? 1 << 32 : 0)
        if let pipeline = pipelines[key] { return pipeline }
        do {
            let constants = MTLFunctionConstantValues()
            var id = shaderId
            constants.setConstantValue(&id, type: .uint, index: 0)
            var opaque = !blend  // (in the room, alpha is coverage over the passthrough: opaque draws cover it)
            constants.setConstantValue(&opaque, type: .bool, index: 1)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try library.makeFunction(
                name: target.room ? "game_vertex_room" : "game_vertex", constantValues: constants)
            descriptor.fragmentFunction = try library.makeFunction(
                name: target.room ? "game_fragment_room" : "game_fragment", constantValues: constants)
            descriptor.depthAttachmentPixelFormat = target.depthFormat
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = target.colorFormat
            if blend {  // glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
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
        if let state = samplers[s] { return state }
        func address(_ mode: Int32) -> MTLSamplerAddressMode {
            mode & 2 != 0 ? .clampToEdge : mode & 1 != 0 ? .mirrorRepeat : .repeat
        }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = s.linear ? .linear : .nearest
        descriptor.magFilter = s.linear ? .linear : .nearest
        descriptor.sAddressMode = address(s.wrapS)
        descriptor.tAddressMode = address(s.wrapT)
        let state = device.makeSamplerState(descriptor: descriptor)
        samplers[s] = state
        return state
    }
}
