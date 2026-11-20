import CompositorServices
import Metal
import MetalKit
import simd
import UIKit

/// Draws what's in the room besides the game: the cartridge, the window's handle, and the title screen (Goddard's
/// face from TitleScreen, behind "PRESS START"), and Mario's gloves over your hands
final class RoomProps {
    private struct PropDraw {
        var model: simd_float4x4
        var color: SIMD4<Float>
        var flags: SIMD4<UInt32>  // x lit, y only through the opening, z alpha tested, w blended into depth
        var uvTransform = SIMD4<Float>(1, 1, 0, 0)  // uv * xy + zw
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
    /// The pipelines (opaque, blended, title opaque, title blended, gloves, the window's picture) by sample count
    private var pipelineSets: [Int: [MTLRenderPipelineState]] = [:]
    /// The room's MSAA samples (the options' anti-aliasing): the pipelines drawn with
    var sampleCount = 1
    private let depthWrite: MTLDepthStencilState
    private let depthTestOnly: MTLDepthStencilState
    private let depthOff: MTLDepthStencilState
    private let quad: MTLBuffer
    /// Mario's gloves (left, right), if they loaded
    private let gloves: [GloveMesh]?
    /// The cartridge's shell, if it loaded
    private let cartridge: CartridgeShell?
    private let white: MTLTexture
    private let label: MTLTexture
    private let pressStart: MTLTexture
    private let ring: MTLTexture
    private let pill: MTLTexture
    /// The title screen's backdrop tile ("SUPER MARIO 64", 80 × 80 of the game's 320 × 240), if the game has it
    private let titleTile: MTLTexture?
    private var samplers: [Int: MTLSamplerState] = [:]

    /// The cartridge's light grey plastic, and the backdrop behind the face (linear)
    private let plastic = SIMD4<Float>(0.46, 0.46, 0.44, 1)
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
              let quad = device.makeBuffer(bytes: Self.quadVertices, length: Self.quadVertices.count * 4)
        else { print("Mario 64 MR: the room's props didn't build"); return nil }
        (self.depthWrite, self.depthTestOnly, self.depthOff, self.quad) = (depthWrite, depthTestOnly, depthOff, quad)
        let gloves = ["LeftGlove", "RightGlove"].compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "glove").flatMap { GloveMesh(device: device, url: $0) }
        }
        if gloves.count < 2 { print("Mario 64 MR: Mario's gloves didn't load") }
        self.gloves = gloves.count == 2 ? gloves : nil
        cartridge = Bundle.main.url(forResource: "Cartridge", withExtension: "shell")
            .flatMap { CartridgeShell(device: device, url: $0) }
        if cartridge == nil { print("Mario 64 MR: the cartridge's shell didn't load") }

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
        pressStart = (try? loader.newTexture(cgImage: Self.gameFontImage("PRESS START") ?? Self.pressStartImage(),
                                              options: options)) ?? white
        titleTile = Self.titleTileImage().flatMap { try? loader.newTexture(cgImage: $0, options: options) }
        ring = (try? loader.newTexture(cgImage: Self.ringImage(), options: options)) ?? white
        pill = (try? loader.newTexture(cgImage: Self.pillImage(), options: options)) ?? white
        guard pipelines() != nil else { print("Mario 64 MR: the room's props didn't build"); return nil }
    }

    // ---------------------------------------------------------------- The cartridge and the window

    func encodeCartridge(_ pose: simd_float4x4, into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        guard let cartridge else { return }
        draw(cartridge.vertices, count: cartridge.indexCount, indices: cartridge.indices, model: pose, color: plastic,
             texture: white, flags: SIMD4(1, 0, 0, 0), blend: false, into: encoder, eye: eye)
        // The label in its recess on the front, as big as its picture fits there; its corners cut out where the
        // picture is clear (a real label's are round)
        let aspect = Float(label.width) / Float(max(label.height, 1))
        let room = cartridge.labelHalf * 2
        let labelSize = aspect > room.x / room.y ? SIMD2(room.x, room.x / aspect) : SIMD2(room.y * aspect, room.y)
        let face = pose * Self.translate(cartridge.labelCenter.x, cartridge.labelCenter.y, cartridge.labelZ + 0.0003)
            * Self.scale(SIMD3(labelSize, 1))
        drawQuad(face, color: SIMD4(1, 1, 1, 1), texture: label, flags: SIMD4(1, 0, 1, 0), into: encoder, eye: eye)
    }

    /// What the level has between the game camera and the window, painted on the glass (window_picture_fragment):
    /// `picture` and `depth` the game's flat picture of its level, `nearer` the window's depth in it
    func encodeWindowPicture(_ window: RoomPlacement, picture: MTLTexture, depth: MTLTexture, nearer: Float,
                             into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        guard let pipelines = pipelines() else { return }
        let h = window.halfSize
        // (a millimetre out of the window: in front of the level behind it, behind the HUD at 2 mm)
        let model = window.roomFromWindow * Self.translate(0, 0, 0.001) * Self.scale(SIMD3(h.x * 2, h.y * 2, 1))
        encoder.setRenderPipelineState(pipelines[5])
        encoder.setDepthStencilState(depthWrite)
        encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        encoder.setCullMode(.none)
        var d = PropDraw(model: model, color: SIMD4(1, 1, 1, 1), flags: SIMD4(0, 0, 0, 0)), e = eye, n = nearer
        encoder.setVertexBuffer(quad, offset: 0, index: 0)
        encoder.setVertexBytes(&d, length: MemoryLayout<PropDraw>.stride, index: 1)
        encoder.setVertexBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
        encoder.setFragmentBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
        encoder.setFragmentBytes(&n, length: 4, index: 3)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.setFragmentTexture(depth, index: 1)
        encoder.setFragmentSamplerState(sampler(clamp: (true, true), mirror: (false, false)), index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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

    // ---------------------------------------------------------------- Mario 128 in your room

    private var countPicture: (count: Int32, texture: MTLTexture, aspect: Float)?

    /// How many Marios there are (Mario's head, ×, the count, in the game's letters), 1.2 cm high, standing at `at`
    /// and turned to face `viewer` (about the room's up)
    func encodeCount(_ count: Int32, at: SIMD3<Float>, facing viewer: SIMD3<Float>, into encoder: MTLRenderCommandEncoder,
                     eye: GameRenderer.RoomEye) {
        if countPicture?.count != count {
            let loader = MTKTextureLoader(device: device)
            guard let image = Self.gameFontImage("@×\(count)"),
                  let texture = try? loader.newTexture(cgImage: image, options: [.SRGB: true, .generateMipmaps: true])
            else { return }
            countPicture = (count, texture, Float(image.width) / Float(image.height))
        }
        guard let picture = countPicture else { return }
        var z = SIMD3(viewer.x - at.x, 0, viewer.z - at.z)
        z = simd_length(z) > 1e-4 ? simd_normalize(z) : SIMD3(0, 0, 1)
        let y = SIMD3<Float>(0, 1, 0), x = simd_cross(y, z), h: Float = 0.012
        let model = simd_float4x4(SIMD4(x * h * picture.aspect, 0), SIMD4(y * h, 0), SIMD4(z, 0), SIMD4(at, 1))
        draw(quad, count: 6, model: model, color: SIMD4(1, 1, 1, 1), texture: picture.texture,
             flags: SIMD4(0, 0, 0, 1), blend: true, depth: depthWrite, into: encoder, eye: eye)
    }

    // ---------------------------------------------------------------- The treasure chest

    /// Each kind's pictures from the game, loaded the first time it's drawn (none: a plain tile)
    private var tilePictures: [SpawnKind: [MTLTexture]] = [:]
    private func pictures(_ kind: SpawnKind) -> [MTLTexture] {
        if let p = tilePictures[kind] { return p }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: true, .generateMipmaps: true]
        let p = (Self.gamePictures(kind.pictures) ?? []).compactMap { try? loader.newTexture(cgImage: $0, options: options) }
        tilePictures[kind] = p
        return p
    }
    /// Open, what the chest holds above it: dimmed where the level can't spawn it, lit up where a hand's on it (the
    /// chest itself is the game's, drawn by the game in the room: TreasureChest.gamePose)
    func encodeChest(_ chest: TreasureChest, into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        guard chest.visible, chest.openness > 0.05 else { return }
        // A warm glow out of it as it opens
        let s = TreasureChest.size
        let up = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, s.y - 0.006, 0, 1))
        draw(quad, count: 6, model: chest.pose * up * Self.scale(SIMD3(s.x * 0.9, s.z * 0.9, 1)),
             color: SIMD4(1, 0.78, 0.35, 0.7 * chest.openness), texture: pill, flags: SIMD4(0, 0, 0, 0), blend: true,
             into: encoder, eye: eye)
        // The tiles: a soft card behind each, the game's picture of it in front
        for kind in SpawnKind.allCases {
            let on = chest.available(kind), hover = chest.hovered == kind
            guard let model = chest.tileModel(kind, grow: hover ? 1.12 : 1) else { continue }
            let pictures = pictures(kind)
            let shade: Float = on ? 1 : 0.3
            for (k, picture) in pictures.enumerated() {
                let half = pictures.count == 2
                let place = half ? Self.translate(k == 0 ? -0.25 : 0.25, 0, 0.02) * Self.scale(SIMD3(0.5, 1, 1))
                    : Self.translate(0, 0, 0.02) * Self.scale(SIMD3(0.82, 0.82, 1))
                draw(quad, count: 6, model: model * place, color: SIMD4(shade, shade, shade, 1), texture: picture,
                     flags: SIMD4(0, 0, 1, 0), blend: false, into: encoder, eye: eye)
            }
            let card = hover ? SIMD4<Float>(1, 0.85, 0.4, 0.85) : SIMD4<Float>(0.08, 0.06, 0.12, on ? 0.6 : 0.3)
            draw(quad, count: 6, model: model * Self.scale(SIMD3(1.15, 1.15, 1)), color: card, texture: pill,
                 flags: SIMD4(0, 0, 0, 1), blend: true, into: encoder, eye: eye)
        }
    }

    /// The chest's tiles you can take as tracking areas, each lit up by the system when you look at it (your gaze is
    /// never the app's): registered on the drawable once a frame (`register`), then drawn into each view's tracking
    /// areas texture with the values they were given
    func chestTrackingAreas(_ chest: TreasureChest, drawable: LayerRenderer.Drawable) -> [(model: simd_float4x4, value: UInt16)] {
        guard chest.visible, chest.openness > 0.6 else { return [] }
        var areas: [(simd_float4x4, UInt16)] = []
        for kind in SpawnKind.allCases where chest.available(kind) {
            guard let model = chest.tileModel(kind) else { continue }
            let area = drawable.addTrackingArea(identifier: .init(rawValue: UInt64(1000 + kind.rawValue)))
            area.addHoverEffect(.automatic)
            let value = area.renderValue.rawValue
            if value != 0 { areas.append((model * Self.scale(SIMD3(1.15, 1.15, 1)), value)) }
        }
        return areas
    }

    func encodeTrackingAreas(_ areas: [(model: simd_float4x4, value: UInt16)], format: MTLPixelFormat,
                             into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        guard !areas.isEmpty, let pipeline = trackingPipeline(format) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        var e = eye
        encoder.setVertexBuffer(quad, offset: 0, index: 0)
        encoder.setVertexBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
        for (model, value) in areas {
            var d = PropDraw(model: model, color: .one, flags: .zero, uvTransform: SIMD4(1, 1, 0, 0)), v = value
            encoder.setVertexBytes(&d, length: MemoryLayout<PropDraw>.stride, index: 1)
            encoder.setFragmentBytes(&v, length: MemoryLayout<UInt16>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private var trackingPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private func trackingPipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let p = trackingPipelines[format] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "prop_vertex")
        d.fragmentFunction = library.makeFunction(name: "tracking_area_fragment")
        d.colorAttachments[0].pixelFormat = format
        guard let p = try? device.makeRenderPipelineState(descriptor: d) else {
            print("Mario 64 MR: the tracking areas' pipeline didn't build")
            return nil
        }
        trackingPipelines[format] = p
        return p
    }

    // ---------------------------------------------------------------- Mario's gloves

    /// Mario's white gloves over your tracked hands (the options' Hands; visionOS then draws your hands under what
    /// the app draws, not over it). Last, and only where something's drawn already: each pixel blended by how much
    /// of the game is there, so out in your room, where the passthrough shows, your hands are your own.
    func encodeGloves(_ hands: [HandState], into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        guard let gloves else { return }
        let skins = hands.prefix(2).enumerated().compactMap { side, hand in
            hand.tracked ? gloves[side].skin(hand).map { (gloves[side], $0) } : nil
        }
        guard !skins.isEmpty, let pipelines = pipelines() else { return }
        var e = eye
        encoder.setCullMode(.none)  // (the cuff is open: its inside shows)
        encoder.setVertexBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
        encoder.setFragmentBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
        encoder.setRenderPipelineState(pipelines[4])
        encoder.setDepthStencilState(depthWrite)
        for (glove, skin) in skins {
            var matrices = skin, dots = glove.dots
            encoder.setVertexBuffer(glove.vertices, offset: 0, index: 0)
            encoder.setFragmentBytes(&dots, length: MemoryLayout<GloveMesh.Dots>.stride, index: 3)
            encoder.setVertexBytes(&matrices, length: matrices.count * MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: glove.indexCount, indexType: .uint32,
                                          indexBuffer: glove.indices, indexBufferOffset: 0)
        }
    }

    // ---------------------------------------------------------------- The title screen

    /// Behind the face, "PRESS START" under it (blinking), and the face: Goddard's camera where the game camera
    /// would be, and its units scaled to set the face in the window's plane
    func encodeTitle(_ title: TitleFrame, window: RoomPlacement, time: Double, into encoder: MTLRenderCommandEncoder,
                     eye: GameRenderer.RoomEye) {
        let h = window.halfSize
        let depth: Float = 1.5, size = SIMD2(h.x * 16, h.y * 16)
        let back = window.roomFromWindow * Self.translate(0, 0, -depth) * Self.scale(SIMD3(size, 1))
        if let titleTile {
            // The game's tiles, laid out as from Goddard's camera (where the game camera would be) they cover its
            // picture: 80 of its 240 rows tall, from its bottom left corner (intro_backdrop_one_image)
            let xScale = (4.0 / 3.0) / RoomPlacement.aspect
            let p00 = abs(title.projection.columns.0.x) * xScale
            let camera = h.x * (p00 > 0.01 ? p00 : 1)
            let grow = (camera + depth) / camera  // (the window's size, out at the backdrop)
            let tile = 80 * h.y / 120 * grow, origin = -h * grow
            // (the quad's uv: x = (u - 0.5) size.x, y = (0.5 - v) size.y; the tile's v runs down from its top)
            let uv = SIMD4(size.x / tile, size.y / tile,
                           (-0.5 * size.x - origin.x) / tile, 1 - (0.5 * size.y - origin.y) / tile)
            draw(quad, count: 6, model: back, color: SIMD4(1, 1, 1, 1), texture: titleTile, flags: SIMD4(0, 1, 0, 0),
                 blend: false, uvTransform: uv, repeating: true, into: encoder, eye: eye)
        } else {
            drawQuad(back, color: backdrop, texture: white, flags: SIMD4(0, 1, 0, 0), into: encoder, eye: eye)
        }

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

    private func drawQuad(_ model: simd_float4x4, color: SIMD4<Float>, texture: MTLTexture, flags: SIMD4<UInt32>,
                          blend: Bool = false, into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        draw(quad, count: 6, model: model, color: color, texture: texture, flags: flags, blend: blend,
             into: encoder, eye: eye)
    }

    /// `count` vertices of `mesh`, or with `indices` (UInt16) that many of them
    private func draw(_ mesh: MTLBuffer, count: Int, indices: MTLBuffer? = nil, model: simd_float4x4, color: SIMD4<Float>, texture: MTLTexture,
                      flags: SIMD4<UInt32>, blend: Bool, depth: MTLDepthStencilState? = nil,
                      uvTransform: SIMD4<Float> = SIMD4(1, 1, 0, 0), repeating: Bool = false,
                      into encoder: MTLRenderCommandEncoder, eye: GameRenderer.RoomEye) {
        guard let pipelines = pipelines() else { return }
        encoder.setRenderPipelineState(pipelines[blend ? 1 : 0])
        encoder.setDepthStencilState(depth ?? (blend ? depthTestOnly : depthWrite))
        encoder.setCullMode(.none)
        var d = PropDraw(model: model, color: color, flags: flags, uvTransform: uvTransform), e = eye
        encoder.setVertexBuffer(mesh, offset: 0, index: 0)
        encoder.setVertexBytes(&d, length: MemoryLayout<PropDraw>.stride, index: 1)
        encoder.setFragmentBytes(&d, length: MemoryLayout<PropDraw>.stride, index: 1)
        encoder.setVertexBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
        encoder.setFragmentBytes(&e, length: MemoryLayout<GameRenderer.RoomEye>.stride, index: 2)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler(clamp: (!repeating, !repeating), mirror: (false, false)), index: 0)
        if let indices {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint16, indexBuffer: indices,
                                          indexBufferOffset: 0)
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }
    }

    /// This sample count's pipelines, made the first time it's drawn with
    private func pipelines() -> [MTLRenderPipelineState]? {
        if let set = pipelineSets[sampleCount] { return set }
        func pipeline(_ vertex: String, _ fragment: String, blend: Bool, overDrawn: Bool = false) -> MTLRenderPipelineState? {
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
            if overDrawn {  // (opaque, by what's there: nothing drawn yet, still nothing)
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].sourceRGBBlendFactor = .destinationAlpha
                d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                d.colorAttachments[0].sourceAlphaBlendFactor = .destinationAlpha
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
                   pipeline("title_vertex", "title_fragment", blend: true),
                   pipeline("glove_vertex", "glove_fragment", blend: false, overDrawn: true),
                   pipeline("prop_vertex", "window_picture_fragment", blend: false)].compactMap { $0 }
        guard set.count == 6 else { return nil }
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

    /// `text` (capitals, digits, spaces; "×", and "@" for Mario's head) in the game's colourful HUD letters, as
    /// print_text lays them out: 16×16 glyphs every 12 pixels (Mario's head 16: segment2's, from your texture packs
    /// first, else base.zip). Nil if a letter isn't there. Its picture is `labelAspect` wide for "PRESS START".
    private static func gameFontImage(_ text: String) -> CGImage? {
        let letters = Array(Set(text).subtracting([" "]))
        // (segment2's: 0 at 0x0000 and A at 0x1400, each 0x200 on; × at 0x5600, Mario's head at 0x5A00)
        var paths: [String] = []
        for c in letters {
            let at: Int
            if c == "×" { at = 0x5600 } else if c == "@" { at = 0x5A00 }
            else if let v = c.asciiValue, let a = Character("A").asciiValue, v >= a, v <= a + 25 { at = 0x1400 + Int(v - a) * 0x200 }
            else if let v = c.asciiValue, let zero = Character("0").asciiValue, v >= zero, v <= zero + 9 { at = Int(v - zero) * 0x200 }
            else { return nil }
            paths.append(String(format: "gfx/textures/segment2/segment2.%05X.rgba16.png", at))
        }
        guard let pictures = gamePictures(paths) else { return nil }
        let glyphs = Dictionary(uniqueKeysWithValues: zip(letters, pictures))
        // (an HD pack's letters are bigger: the picture is made at their size)
        let k = max(1, (glyphs.values.map { $0.width }.max() ?? 16) / 16)
        let advance = { (c: Character) in c == "@" ? 16 : 12 }
        let width = text.dropLast().reduce(0) { $0 + advance($1) } + 16
        let size = CGSize(width: width * k, height: 16 * k)
        return image(size) { context in
            context.clear(CGRect(origin: .zero, size: size))
            context.interpolationQuality = .none
            // (UIKit's context is flipped: drawn the right way up)
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            var x = 0
            for c in text {
                if let glyph = glyphs[c] { context.draw(glyph, in: CGRect(x: x * k, y: 0, width: 16 * k, height: 16 * k)) }
                x += advance(c)
            }
        }
    }

    /// The game's pictures at `paths` in its resource pack (your texture packs' first, else base.zip); nil if one
    /// isn't there
    private static func gamePictures(_ paths: [String]) -> [CGImage]? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("Data/sm64/res/base.zip"),
              let zip = ZipArchive(url: base) else { return nil }
        let packs = TexturePacks.Reader()
        var pictures: [CGImage] = []
        for path in paths {
            guard let png = packs.read(path) ?? zip.read(path), let picture = UIImage(data: png)?.cgImage else { return nil }
            pictures.append(picture)
        }
        return pictures
    }

    /// The title screen's backdrop tile, as intro_geo.c draws it: mario_title_texture_table's four 80 × 20 strips,
    /// top to bottom (at an HD pack's size, if it has them)
    private static func titleTileImage() -> CGImage? {
        let strips = ["001C0", "00E40", "01AC0", "02740"].map { "gfx/textures/title_screen_bg/title_screen_bg.\($0).rgba16.png" }
        guard let pictures = gamePictures(strips) else { return nil }
        let k = max(1, (pictures.map { $0.width }.max() ?? 80) / 80)
        let size = CGSize(width: 80 * k, height: 80 * k)
        return image(size) { context in
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            for (i, strip) in pictures.enumerated() {  // (the first at the top)
                context.draw(strip, in: CGRect(x: 0, y: (3 - i) * 20 * k, width: 80 * k, height: 20 * k))
            }
        }
    }

    /// "PRESS START"'s picture, width over height (gameFontImage's: 10 × 12 + 16 by 16)
    static let labelAspect: Float = 136.0 / 16.0

    /// (without the game's letters) "PRESS START" in the system's font, the same shape
    private static func pressStartImage() -> CGImage {
        image(CGSize(width: 544, height: 64)) { context in
            context.clear(CGRect(x: 0, y: 0, width: 544, height: 64))
            let font = UIFont.systemFont(ofSize: 48, weight: .heavy)
            let shadow = NSAttributedString(string: "PRESS START", attributes: [
                .font: font, .foregroundColor: UIColor(red: 0.55, green: 0.05, blue: 0.05, alpha: 1)])
            let text = NSAttributedString(string: "PRESS START", attributes: [
                .font: font, .foregroundColor: UIColor(red: 1, green: 0.9, blue: 0.2, alpha: 1)])
            let size = text.size(), at = CGPoint(x: (544 - size.width) / 2, y: (64 - size.height) / 2)
            shadow.draw(at: CGPoint(x: at.x + 3, y: at.y + 3))
            text.draw(at: at)
        }
    }
}
