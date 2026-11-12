import Metal
import MetalKit
import simd
import UIKit

/// Draws what's in the room besides the game: the cartridge, the window's frame, and the title screen (Goddard's
/// face from TitleScreen, behind "PRESS START")
final class RoomProps {
    private struct PropDraw {
        var model: simd_float4x4
        var color: SIMD4<Float>
        var flags: SIMD4<UInt32>  // x lit, y only through the opening, z alpha tested, w blended into depth
    }
    private struct TitleDraw {
        var roomFromGd: simd_float4x4
        var colorCombine: SIMD4<UInt8>
        var alphaCombine: SIMD4<UInt8>
        var prim: SIMD4<Float>
        var env: SIMD4<Float>
        var flags: SIMD4<UInt32>
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat
    /// The pipelines (opaque, blended, title opaque, title blended) by sample count
    private var pipelineSets: [Int: [MTLRenderPipelineState]] = [:]
    /// The room's MSAA samples (the options' anti-aliasing): the pipelines drawn with
    var sampleCount = 1
    private let depthWrite: MTLDepthStencilState
    private let depthTestOnly: MTLDepthStencilState
    private let depthOff: MTLDepthStencilState
    private let box: MTLBuffer
    private let quad: MTLBuffer
    private let white: MTLTexture
    private let label: MTLTexture
    private let pressStart: MTLTexture
    private let ring: MTLTexture
    private let pill: MTLTexture
    private var samplers: [Int: MTLSamplerState] = [:]

    /// The cartridge's plastic, and the backdrop behind the face (linear)
    private let plastic = SIMD4<Float>(0.16, 0.16, 0.17, 1)
    private let backdrop = SIMD4<Float>(0.004, 0.008, 0.03, 1)

    init?(device: MTLDevice, library: MTLLibrary, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        self.device = device
        self.library = library
        (self.colorFormat, self.depthFormat) = (colorFormat, depthFormat)
        func depth(test: Bool, write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = test ? .greaterEqual : .always  // (reversed depth)
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }
        guard let depthWrite = depth(test: true, write: true), let depthTestOnly = depth(test: true, write: false),
              let depthOff = depth(test: false, write: false),
              let box = device.makeBuffer(bytes: Self.boxVertices, length: Self.boxVertices.count * 4),
              let quad = device.makeBuffer(bytes: Self.quadVertices, length: Self.quadVertices.count * 4)
        else { print("Mario 64 MR: the room's props didn't build"); return nil }
        (self.depthWrite, self.depthTestOnly, self.depthOff, self.box, self.quad) = (depthWrite, depthTestOnly, depthOff, box, quad)

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: true, .generateMipmaps: true]
        let white: MTLTexture
        do {
            white = try loader.newTexture(cgImage: Self.image(CGSize(width: 4, height: 4)) { _ in
                UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }, options: options)
        } catch {
            print("Mario 64 MR: the props' textures didn't load: \(error)")
            return nil
        }
        self.white = white
        // The label: label.png or label.jpg in the app's Documents folder (the Files app), else the one the
        // installer put in the app (--label), else a plain one
        let folders = [URL.documentsDirectory] + [Bundle.main.resourceURL?.appendingPathComponent("Data")].compactMap { $0 }
        let custom = folders.lazy.flatMap { folder in
            ["label.png", "label.jpg", "label.jpeg"].lazy.map { folder.appendingPathComponent($0) }
        }.first { FileManager.default.fileExists(atPath: $0.path) }
        label = custom.flatMap { try? loader.newTexture(URL: $0, options: options) }
            ?? (try? loader.newTexture(cgImage: Self.plainLabel(), options: options)) ?? white
        pressStart = (try? loader.newTexture(cgImage: Self.pressStartImage(), options: options)) ?? white
        ring = (try? loader.newTexture(cgImage: Self.ringImage(), options: options)) ?? white
        pill = (try? loader.newTexture(cgImage: Self.pillImage(), options: options)) ?? white
        guard pipelines() != nil else { print("Mario 64 MR: the room's props didn't build"); return nil }
    }

    // ---------------------------------------------------------------- The cartridge and the frame

    func encodeCartridge(_ pose: simd_float4x4, into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        let size = Cartridge.size
        drawBox(pose * Self.scale(size), color: plastic, into: encoder, eye: eye)
        // A ridge along its top, as cartridges have
        drawBox(pose * Self.translate(0, size.y * 0.47, 0) * Self.scale(SIMD3(size.x * 0.92, size.y * 0.12, size.z * 1.12)),
                color: plastic * 0.8, into: encoder, eye: eye)
        let face = pose * Self.translate(0, size.y * 0.05, size.z / 2 + 0.0006)
            * Self.scale(SIMD3(size.x * 0.8, size.y * 0.66, 1))
        drawQuad(face, color: SIMD4(1, 1, 1, 1), texture: label, flags: SIMD4(1, 0, 0, 0), into: encoder, eye: eye)
    }

    func encodeFrame(_ window: RoomPlacement, into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        let h = window.halfSize, t = window.frameThickness, d: Float = 0.03
        let bars: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0, h.y + t / 2, 0), SIMD3(2 * h.x + 2 * t, t, d)), (SIMD3(0, -h.y - t / 2, 0), SIMD3(2 * h.x + 2 * t, t, d)),
            (SIMD3(-h.x - t / 2, 0, 0), SIMD3(t, 2 * h.y, d)), (SIMD3(h.x + t / 2, 0, 0), SIMD3(t, 2 * h.y, d)),
        ]
        for (at, size) in bars {
            drawBox(window.roomFromWindow * Self.translate(at.x, at.y, at.z) * Self.scale(size), color: plastic,
                    into: encoder, eye: eye)
        }
    }

    /// The handle under the window, as visionOS draws its windows' bar: a soft white pill, brighter and a little
    /// wider while held
    func encodeHandle(_ window: RoomPlacement, held: Bool, into encoder: MTLRenderCommandEncoder,
                      eye: GameRenderer.RoomEye) {
        let handle = window.handle, grow: Float = held ? 1.15 : 1
        let model = window.roomFromWindow * Self.translate(handle.center.x, handle.center.y, 0)
            * Self.scale(SIMD3(handle.half.x * 2 * grow, handle.half.y * 2 * grow, 1))
        draw(quad, count: 6, model: model, color: SIMD4(1, 1, 1, held ? 0.95 : 0.6), texture: pill,
             flags: SIMD4(0, 0, 0, 1), blend: true, depth: depthWrite, into: encoder, eye: eye)
    }

    /// The glowing circle on a table, `radius` metres, facing up: where the window goes down into a diorama, and the
    /// diorama's base
    func encodeCircle(at center: SIMD3<Float>, radius: Float, glow: Float, into encoder: MTLRenderCommandEncoder,
                      eye: GameRenderer.RoomEye) {
        // (the quad faces +z: turned to face up, a millimetre over the table)
        let flat = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0),
                                 SIMD4(center.x, center.y + 0.002, center.z, 1))
        let model = flat * Self.scale(SIMD3(radius * 2 * Self.ringMargin, radius * 2 * Self.ringMargin, 1))
        // Twice: once over everything, dimmer, so it still shows where the level reaching out of the window (or the
        // room's own surfaces, a little above the table) is in front of it; then depth tested, so where nothing is
        // in front it's brighter, and in the depth buffer where it shows: visionOS reprojects each frame to where
        // your head is by its depth, and what has none it takes for infinitely far, so it would swim and flicker
        draw(quad, count: 6, model: model, color: SIMD4(0.55, 0.85, 1, glow * 0.55), texture: ring,
             flags: SIMD4(0, 0, 0, 0), blend: true, depth: depthOff, into: encoder, eye: eye)
        draw(quad, count: 6, model: model, color: SIMD4(0.55, 0.85, 1, glow * 0.6), texture: ring,
             flags: SIMD4(0, 0, 0, 1), blend: true, depth: depthWrite, into: encoder, eye: eye)
    }

    // ---------------------------------------------------------------- The title screen

    /// Behind the face, "PRESS START" under it (blinking), and the face: Goddard's camera where the game camera
    /// would be, and its units scaled to set the face in the window's plane
    func encodeTitle(_ title: TitleFrame, window: RoomPlacement, time: Double, into encoder: MTLRenderCommandEncoder,
                     eye: GameRenderer.RoomEye) {
        let h = window.halfSize
        let back = window.roomFromWindow * Self.translate(0, 0, -1.5) * Self.scale(SIMD3(h.x * 16, h.y * 16, 1))
        drawQuad(back, color: backdrop, texture: white, flags: SIMD4(0, 1, 0, 0), into: encoder, eye: eye)

        if let vertices = title.vertices {
            let roomFromGd3D = Self.roomFromTitle(title, window: window)
            let k = h.y * 4 / 3 / 160
            let roomFromScreen = window.roomFromWindow * simd_float4x4(
                SIMD4(k, 0, 0, 0), SIMD4(0, -h.y / 120, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-160 * k, h.y, 0.003, 1))
            encoder.setVertexBuffer(vertices, offset: 0, index: 0)
            var e = eye
            encoder.setVertexBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
            encoder.setFragmentBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
            for draw in title.draws {
                let blend = draw.flags & 2 != 0
                guard let pipelines = pipelines() else { return }
                encoder.setRenderPipelineState(pipelines[blend ? 3 : 2])
                let test = draw.flags & 8 != 0, write = draw.flags & 16 != 0
                encoder.setDepthStencilState(!test ? depthOff : write && !blend ? depthWrite : depthTestOnly)
                encoder.setDepthBias(draw.flags & 32 != 0 ? 4 : 0, slopeScale: draw.flags & 32 != 0 ? 2 : 0, clamp: 0)
                encoder.setCullMode(.none)
                var d = TitleDraw(roomFromGd: draw.screen ? roomFromScreen : roomFromGd3D,
                                  colorCombine: draw.colorCombine, alphaCombine: draw.alphaCombine,
                                  prim: draw.prim, env: draw.env,
                                  flags: SIMD4(draw.flags, draw.texture == nil ? 0 : 1, 0, 0))
                encoder.setVertexBytes(&d, length: MemoryLayout<TitleDraw>.stride, index: 1)
                encoder.setFragmentBytes(&d, length: MemoryLayout<TitleDraw>.stride, index: 1)
                encoder.setFragmentTexture(draw.texture ?? white, index: 0)
                encoder.setFragmentSamplerState(sampler(clamp: draw.clamp, mirror: draw.mirror), index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: draw.firstVertex, vertexCount: draw.vertexCount)
            }
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        let label = window.startLabel
        let blink = Float(0.65 + 0.35 * cos(time * 4))
        let quad = window.roomFromWindow * Self.translate(label.center.x, label.center.y, 0.004)
            * Self.scale(SIMD3(label.half.x * 2, label.half.y * 2, 1))
        draw(self.quad, count: 6, model: quad, color: SIMD4(1, 1, 1, blink), texture: pressStart,
             flags: SIMD4(0, 0, 0, 1), blend: true, depth: depthWrite, into: encoder, eye: eye)
    }

    /// Goddard's eye space into the room: its camera at the game camera's place in front of the window (where its
    /// field of view spans the opening), its units scaled so the face is in the window's plane
    static func roomFromTitle(_ title: TitleFrame, window: RoomPlacement) -> simd_float4x4 {
        let xScale = (4.0 / 3.0) / RoomPlacement.aspect
        let p00 = abs(title.projection.columns.0.x) * xScale
        let distance = window.halfSize.x * (p00 > 0.01 ? p00 : 1)
        let s = distance / title.depth
        // (Goddard's view is off-centre: its projection shifts the picture, x' = x + (P20 / P00) z, and so on)
        let p = title.projection
        var shear = matrix_identity_float4x4
        if abs(p.columns.0.x) > 0.01, abs(p.columns.1.y) > 0.01 {
            shear.columns.2.x = p.columns.2.x / p.columns.0.x
            shear.columns.2.y = p.columns.2.y / p.columns.1.y
        }
        return window.roomFromWindow * translate(0, 0, distance) * simd_float4x4(diagonal: SIMD4(s, s, s, 1)) * shear
    }

    // ---------------------------------------------------------------- Drawing

    private func drawBox(_ model: simd_float4x4, color: SIMD4<Float>, into encoder: MTLRenderCommandEncoder,
                         eye: GameRenderer.RoomEye) {
        draw(box, count: 36, model: model, color: color, texture: white, flags: SIMD4(1, 0, 0, 0), blend: false,
             into: encoder, eye: eye)
    }

    private func drawQuad(_ model: simd_float4x4, color: SIMD4<Float>, texture: MTLTexture, flags: SIMD4<UInt32>,
                          blend: Bool = false, into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        draw(quad, count: 6, model: model, color: color, texture: texture, flags: flags, blend: blend,
             into: encoder, eye: eye)
    }

    private func draw(_ mesh: MTLBuffer, count: Int, model: simd_float4x4, color: SIMD4<Float>, texture: MTLTexture,
                      flags: SIMD4<UInt32>, blend: Bool, depth: MTLDepthStencilState? = nil,
                      into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        guard let pipelines = pipelines() else { return }
        encoder.setRenderPipelineState(pipelines[blend ? 1 : 0])
        encoder.setDepthStencilState(depth ?? (blend ? depthTestOnly : depthWrite))
        encoder.setCullMode(.none)
        var d = PropDraw(model: model, color: color, flags: flags), e = eye
        encoder.setVertexBuffer(mesh, offset: 0, index: 0)
        encoder.setVertexBytes(&d, length: MemoryLayout<PropDraw>.stride, index: 1)
        encoder.setFragmentBytes(&d, length: MemoryLayout<PropDraw>.stride, index: 1)
        encoder.setVertexBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
        encoder.setFragmentBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler(clamp: (true, true), mirror: (false, false)), index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
    }

    /// This sample count's pipelines, made the first time it's drawn with
    private func pipelines() -> [MTLRenderPipelineState]? {
        if let set = pipelineSets[sampleCount] { return set }
        func pipeline(_ vertex: String, _ fragment: String, blend: Bool) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.depthAttachmentPixelFormat = depthFormat
            d.colorAttachments[0].pixelFormat = colorFormat
            d.rasterSampleCount = sampleCount
            if blend {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .one
                d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                print("Mario 64 MR: \(fragment) didn't build: \(error)")
                return nil
            }
        }
        let set = [pipeline("prop_vertex", "prop_fragment", blend: false),
                   pipeline("prop_vertex", "prop_fragment", blend: true),
                   pipeline("title_vertex", "title_fragment", blend: false),
                   pipeline("title_vertex", "title_fragment", blend: true)].compactMap { $0 }
        guard set.count == 4 else { return nil }
        pipelineSets[sampleCount] = set
        return set
    }

    private func sampler(clamp: (x: Bool, y: Bool), mirror: (x: Bool, y: Bool)) -> MTLSamplerState? {
        let key = (clamp.x ? 1 : 0) | (clamp.y ? 2 : 0) | (mirror.x ? 4 : 0) | (mirror.y ? 8 : 0)
        if let s = samplers[key] { return s }
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.mipFilter = .linear
        d.maxAnisotropy = 16  // (the circle on the table is mostly seen at a low angle)
        d.sAddressMode = clamp.x ? .clampToEdge : mirror.x ? .mirrorRepeat : .repeat
        d.tAddressMode = clamp.y ? .clampToEdge : mirror.y ? .mirrorRepeat : .repeat
        let s = device.makeSamplerState(descriptor: d)
        samplers[key] = s
        return s
    }

    // ---------------------------------------------------------------- Meshes and pictures

    static func translate(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(x, y, z, 1))
    }
    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 { simd_float4x4(diagonal: SIMD4(s, 1)) }

    /// A unit cube about the origin: position, normal, uv a vertex
    private static let boxVertices: [Float] = {
        var out: [Float] = []
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [  // normal, u, v
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
        ]
        for (n, u, v) in faces {
            let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, -1), (1, 1), (-1, 1)]
            for (a, b) in corners {
                let p = (n + u * a + v * b) * 0.5
                out += [p.x, p.y, p.z, n.x, n.y, n.z, (a + 1) / 2, (1 - b) / 2]
            }
        }
        return out
    }()

    /// A unit square in x and y, facing +z, uv's origin at its top left
    private static let quadVertices: [Float] = {
        let corners: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, -1), (1, 1), (-1, 1)]
        return corners.flatMap { a, b in [a / 2, b / 2, 0, 0, 0, 1, (a + 1) / 2, (1 - b) / 2] }
    }()

    private static func image(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard  // (8 bits a channel, as the texture loader takes them)
        return UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }.cgImage!
    }

    /// The plain label: a light panel with a darker border, nothing on it
    private static func plainLabel() -> CGImage {
        image(CGSize(width: 256, height: 200)) { _ in
            UIColor(white: 0.32, alpha: 1).setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 256, height: 200))
            UIColor(white: 0.86, alpha: 1).setFill(); UIRectFill(CGRect(x: 10, y: 10, width: 236, height: 180))
        }
    }

    /// A white capsule filling the picture (its ends round), soft-edged
    private static func pillImage() -> CGImage {
        let w = 512, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let r = Float(h) / 2 - 2
        for y in 0..<h {
            for x in 0..<w {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let cx = min(max(px, Float(h) / 2), Float(w) - Float(h) / 2)
                let d = ((px - cx) * (px - cx) + (py - Float(h) / 2) * (py - Float(h) / 2)).squareRoot()
                let a = 1 - simd_smoothstep(r - 1.5, r + 1.5, d)
                let i = (y * w + x) * 4
                pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255; pixels[i + 3] = UInt8(a * 255)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// How far past the ring the circle's picture reaches (its half width over the ring's radius), so the glow
    /// fades out before the picture's edge
    private static let ringMargin: Float = 1.45

    /// A ring of light (radius 1 / ringMargin of the picture's half width) glowing out on both sides, a faint fill
    /// inside, and a dark band just outside it so it stands out on a light table, all soft-edged (a hard edge
    /// shimmers at a low angle)
    private static func ringImage() -> CGImage {
        let size = 1024
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let dx = (Float(x) + 0.5) / Float(size) * 2 - 1, dy = (Float(y) + 0.5) / Float(size) * 2 - 1
                let r = (dx * dx + dy * dy).squareRoot() * ringMargin
                let ring = exp(-pow((r - 1) / 0.045, 2)), glow = exp(-pow((r - 1) / 0.16, 2)) * 0.6
                let fill = 0.18 * (1 - simd_smoothstep(0.9, 1.0, r))
                let light = min(1, ring + glow + fill), dark = 0.4 * exp(-pow((r - 1.12) / 0.08, 2))
                // (the light over the dark band)
                let a = light + dark * (1 - light), v = a > 0 ? light / a : 1
                let i = (y * size + x) * 4
                let c = UInt8(v * 255)
                pixels[i] = c; pixels[i + 1] = c; pixels[i + 2] = c; pixels[i + 3] = UInt8(a * 255)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    private static func pressStartImage() -> CGImage {
        image(CGSize(width: 512, height: 92)) { context in
            context.clear(CGRect(x: 0, y: 0, width: 512, height: 92))
            let font = UIFont.systemFont(ofSize: 64, weight: .heavy)
            let shadow = NSAttributedString(string: "PRESS START", attributes: [
                .font: font, .foregroundColor: UIColor(red: 0.55, green: 0.05, blue: 0.05, alpha: 1)])
            let text = NSAttributedString(string: "PRESS START", attributes: [
                .font: font, .foregroundColor: UIColor(red: 1, green: 0.9, blue: 0.2, alpha: 1)])
            let size = text.size(), at = CGPoint(x: (512 - size.width) / 2, y: (92 - size.height) / 2)
            shadow.draw(at: CGPoint(x: at.x + 4, y: at.y + 4))
            text.draw(at: at)
        }
    }
}
