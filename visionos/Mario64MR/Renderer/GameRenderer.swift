import Metal
import MetalKit

/// Draws GameFrames as sm64ex's OpenGL renderer would (gfx_opengl.c): one pipeline per combiner and blend, depth
/// test LEQUAL, decals pulled forward, the game's viewport and scissor scaled to the drawable.
final class GameRenderer: NSObject, MTKViewDelegate {
    static let colorFormat = MTLPixelFormat.bgra8Unorm  // (the game's colours are written as they are, as on OpenGL)
    static let depthFormat = MTLPixelFormat.depth32Float

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private let frames: GameFrames
    private var pipelines: [UInt64: MTLRenderPipelineState] = [:]
    private var depthStates: [Int: MTLDepthStencilState] = [:]
    private var samplers: [GameFrame.Sampler: MTLSamplerState] = [:]
    private let blank: MTLTexture
    private let inFlight = DispatchSemaphore(value: 3)
    private(set) var framesDrawn = 0

    init?(device: MTLDevice, frames: GameFrames) {
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
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let blank = device.makeTexture(descriptor: descriptor) else { return nil }
        let white: [UInt8] = [255, 255, 255, 255]
        blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: white, bytesPerRow: 4)
        self.blank = blank
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = Self.colorFormat
        view.depthStencilPixelFormat = Self.depthFormat
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
        let target = SIMD2(Double(drawable.texture.width), Double(drawable.texture.height))
        encode(frame, into: encoder, target: target)
        encoder.endEncoding()
        commands.present(drawable)
        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commands.commit()
        framesDrawn += 1
    }

    /// The frame's draws into a render pass whose target is `target` pixels, the game's window stretched over it
    func encode(_ frame: GameFrame, into encoder: MTLRenderCommandEncoder, target: SIMD2<Double>) {
        guard let vertices = frame.vertices else { return }
        let scale = target / SIMD2(Double(frame.size.x), Double(frame.size.y))
        var number = frame.number
        encoder.setFragmentBytes(&number, length: 4, index: 0)
        encoder.setCullMode(.none)
        for draw in frame.draws {
            guard let pipeline = pipeline(draw.shaderId, blend: draw.blend) else { continue }
            // OpenGL's rectangles count from the bottom left of the game's window, Metal's from the top left
            let v = draw.viewport
            encoder.setViewport(MTLViewport(
                originX: Double(v.x) * scale.x, originY: Double(frame.size.y - v.y - v.w) * scale.y,
                width: Double(v.z) * scale.x, height: Double(v.w) * scale.y, znear: 0, zfar: 1))
            guard let scissor = scissorRect(draw.scissor, frame: frame.size, scale: scale, target: target) else {
                continue
            }
            encoder.setScissorRect(scissor)
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState(test: draw.depthTest, write: draw.depthWrite))
            encoder.setDepthBias(draw.decal ? -2 : 0, slopeScale: draw.decal ? -2 : 0, clamp: 0)
            encoder.setFragmentTexture(draw.textures.0 ?? blank, index: 0)
            encoder.setFragmentTexture(draw.textures.1 ?? blank, index: 1)
            encoder.setFragmentSamplerState(sampler(draw.samplers.0), index: 0)
            encoder.setFragmentSamplerState(sampler(draw.samplers.1), index: 1)
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

    private func pipeline(_ shaderId: UInt32, blend: Bool) -> MTLRenderPipelineState? {
        let key = UInt64(shaderId) | (blend ? 1 << 32 : 0)
        if let pipeline = pipelines[key] { return pipeline }
        do {
            let constants = MTLFunctionConstantValues()
            var id = shaderId
            constants.setConstantValue(&id, type: .uint, index: 0)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try library.makeFunction(name: "game_vertex", constantValues: constants)
            descriptor.fragmentFunction = try library.makeFunction(name: "game_fragment", constantValues: constants)
            descriptor.depthAttachmentPixelFormat = Self.depthFormat
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = Self.colorFormat
            if blend {  // glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA), alpha included
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .sourceAlpha
                color.sourceAlphaBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
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

    private func depthState(test: Bool, write: Bool) -> MTLDepthStencilState? {
        // OpenGL writes no depth while the test is off
        let key = (test ? 1 : 0) | (write && test ? 2 : 0)
        if let state = depthStates[key] { return state }
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = test ? .lessEqual : .always
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
