import Foundation
import Metal
import simd

/// One frame of the title screen's face (libgoddard), for the room's renderer
struct TitleFrame {
    struct Draw {
        var firstVertex: Int
        var vertexCount: Int
        var texture: MTLTexture?
        var flags: UInt32           // GD_BATCH_*
        var colorCombine: SIMD4<UInt8>
        var alphaCombine: SIMD4<UInt8>
        var prim: SIMD4<Float>
        var env: SIMD4<Float>
        var clamp: (x: Bool, y: Bool), mirror: (x: Bool, y: Bool)

        var screen: Bool { flags & 1 != 0 }
    }
    var vertices: MTLBuffer?
    var draws: [Draw]
    /// Goddard's perspective (as simd reads the row-vector matrix: clip = projection * v)
    var projection: simd_float4x4
    /// How far in front of Goddard's camera the face is, its units (to set it in the window's plane)
    var depth: Float
}

/// A hand on the title screen's face: where it points in Goddard's 320×240 screen, whether it pinches (A), and how
/// far it has pulled towards you since it took hold, Goddard's units
struct TitleCursor {
    var x: Float, y: Float
    var pinching: Bool
    var pull: Float
}

/// The title screen's face, Goddard from the decomp (libgoddard), run on the game thread while the window shows
/// the title in the room: your two pinches are its two hands (gd_api_tick, gd_api_set_hand2), their pull towards
/// you its depth (gd_api_set_drag_z). Its sounds play through libsm64's audio, mixed into the game's.
final class TitleScreen {
    private let device: MTLDevice
    private var textures: [MTLTexture] = []
    private var depth: Float?
    private var audioBuffer = [Int16](repeating: 0, count: 2 * 2 * 600)

    /// The menu sounds Goddard asks for (play_menu_sounds, sound_init.c), first flag first
    private static let sounds: [(flag: Int32, sound: UInt32)] = [
        (0x01, 0x700A_0080), (0x02, 0x700B_0080), (0x04, 0x700C_0080), (0x08, 0x7008_0080),
        (0x10, 0x7008_0080), (0x20, 0x7009_0080), (0x40, 0x7006_0080), (0x80, 0x7007_0080),
    ]

    /// Gives Goddard its textures from the resource pack (base.zip: sm64ex's, made from your ROM), or your texture
    /// packs (TexturePacks), as the N64's formats and sizes; and starts libsm64's audio from the ROM, for its sounds
    init?(device: MTLDevice, pack: URL, rom: Data?) {
        self.device = device
        guard let zip = ZipArchive(url: pack) else { return nil }
        let packs = TexturePacks.Reader()  // (your texture packs' face, if they have one)
        var missing: [String] = []
        for i in 0..<gd_api_texture_slot_count() {
            var width: Int32 = 0, height: Int32 = 0
            guard let cName = gd_api_texture_slot(i, &width, &height) else { continue }
            let name = String(cString: cName)
            let path = "gfx/textures/intro_raw/\(name).png", format = (name as NSString).pathExtension
            let fromPack = packs.read(path).flatMap {
                N64Texture.encode(png: $0, format: format, width: Int(width), height: Int(height))
            }
            guard let bytes = fromPack ?? zip.read(path).flatMap({
                      N64Texture.encode(png: $0, format: format, width: Int(width), height: Int(height))
                  }),
                  bytes.withUnsafeBufferPointer({ gd_api_set_texture(cName, $0.baseAddress, Int32($0.count)) }) == 1
            else { missing.append(name); continue }
        }
        if !missing.isEmpty { print("Mario 64 MR: Goddard's textures missing: \(missing)") }
        guard gd_api_init() == 1 else { return nil }
        if let rom { rom.withUnsafeBytes { sm64_audio_init($0.bindMemory(to: UInt8.self).baseAddress) } }
    }

    /// One frame of the face: `hands[0]` drives Goddard's own cursor (with the pad), `hands[1]` its second
    func tick(_ hands: [TitleCursor?], pad: GamePad.State) -> TitleFrame {
        let one = hands.first ?? nil, two = hands.count > 1 ? hands[1] : nil
        gd_api_set_drag_z(0, one?.pull ?? 0)
        gd_api_set_drag_z(1, two?.pull ?? 0)
        gd_api_set_hand2(two == nil ? 0 : 1, two?.x ?? 0, two?.y ?? 0, two?.pinching == true ? 1 : 0, 0, 0, 0)
        var buttons = pad.buttons & GamePad.a
        if one?.pinching == true { buttons |= GamePad.a }
        let sfx = gd_api_tick(one == nil ? 0 : 1, one?.x ?? 0, one?.y ?? 0, buttons,
                              one == nil ? pad.stickX : 0, one == nil ? pad.stickY : 0, 0)
        if let sound = Self.sounds.first(where: { sfx & $0.flag != 0 }) {
            sm64_play_sound_global(Int32(bitPattern: sound.sound))
        }
        return frame()
    }

    /// libsm64's audio for one game frame (its sounds), `queued` frames of it waiting to play
    func audio(queued: Int, into push: (UnsafePointer<Int16>, Int) -> Void) {
        let frames = Int(sm64_audio_tick(UInt32(queued), 1100, &audioBuffer)) * 2
        guard frames > 0 else { return }
        audioBuffer.withUnsafeBufferPointer { push($0.baseAddress!, min(frames * 2, $0.count)) }
    }

    private func frame() -> TitleFrame {
        updateTextures()
        var vertexCount: Int32 = 0, batchCount: Int32 = 0
        let vertices = gd_api_vertices(&vertexCount)
        let batches = gd_api_batches(&batchCount)
        var projection = [Float](repeating: 0, count: 16)
        gd_api_projection(&projection)
        let p = simd_float4x4(SIMD4(projection[0], projection[1], projection[2], projection[3]),
                              SIMD4(projection[4], projection[5], projection[6], projection[7]),
                              SIMD4(projection[8], projection[9], projection[10], projection[11]),
                              SIMD4(projection[12], projection[13], projection[14], projection[15]))
        guard let vertices, vertexCount > 0, let batches, batchCount > 0 else {
            return TitleFrame(vertices: nil, draws: [], projection: p, depth: depth ?? 1000)
        }
        let buffer = device.makeBuffer(bytes: vertices, length: Int(vertexCount) * MemoryLayout<GdVertex>.stride,
                                       options: .storageModeShared)
        var draws: [TitleFrame.Draw] = []
        var zSum: Float = 0, zCount = 0
        for b in UnsafeBufferPointer(start: batches, count: Int(batchCount)) where b.vertexCount > 0 {
            func color(_ c: (UInt8, UInt8, UInt8, UInt8)) -> SIMD4<Float> {
                SIMD4(Float(c.0), Float(c.1), Float(c.2), Float(c.3)) / 255
            }
            let textured = b.flags & 256 != 0 && b.texture >= 0 && Int(b.texture) < textures.count
            draws.append(TitleFrame.Draw(
                firstVertex: Int(b.firstVertex), vertexCount: Int(b.vertexCount),
                texture: textured ? textures[Int(b.texture)] : nil, flags: b.flags,
                colorCombine: SIMD4(b.colorCombine.0, b.colorCombine.1, b.colorCombine.2, b.colorCombine.3),
                alphaCombine: SIMD4(b.alphaCombine.0, b.alphaCombine.1, b.alphaCombine.2, b.alphaCombine.3),
                prim: color(b.prim), env: color(b.env),
                clamp: (b.clampS != 0, b.clampT != 0), mirror: (b.mirrorS != 0, b.mirrorT != 0)))
            if depth == nil, b.flags & 1 == 0 {
                for v in Int(b.firstVertex)..<Int(b.firstVertex + b.vertexCount) where v < vertexCount {
                    zSum += vertices[v].pos.2
                    zCount += 1
                }
            }
        }
        if depth == nil, zCount > 0 { depth = max(1, -zSum / Float(zCount)) }
        return TitleFrame(vertices: buffer, draws: draws, projection: p, depth: depth ?? 1000)
    }

    /// Goddard decodes its textures as it first uses them: new ones become Metal textures
    private func updateTextures() {
        let count = Int(gd_api_texture_count())
        while textures.count < count {
            let index = Int32(textures.count)
            var width: Int32 = 0, height: Int32 = 0
            gd_api_texture_size(index, &width, &height)
            let w = max(Int(width), 1), h = max(Int(height), 1)
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            if width > 0, height > 0 { gd_api_texture_rgba(index, &rgba) }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h,
                                                                      mipmapped: false)
            guard let texture = device.makeTexture(descriptor: descriptor) else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: rgba, bytesPerRow: w * 4)
            textures.append(texture)
        }
    }
}

/// Your hands on the title screen (game thread): each pinch takes hold of the face where it is as you see it (from
/// your eyes, through the pinch, onto the window: at arm's length or at the glass), and pulls it as the hand moves;
/// a pinch on "PRESS START" presses Start
final class TitleHands {
    private var held: [Float?] = [nil, nil]  // (the window-space depth each pinch took hold at)
    private var wasPinching = [false, false]

    /// The cursors for TitleScreen.tick, and whether Start was pinched; `eye` is your head in the window's space
    /// (without it, the pinch is seen from Goddard's camera)
    func update(hands: [HandState], geometry g: RoomGeometry, frame: TitleFrame?,
                eye: SIMD3<Float>?) -> (cursors: [TitleCursor?], start: Bool) {
        var cursors: [TitleCursor?] = [nil, nil]
        var start = false
        let h = g.halfSize
        // Goddard's camera, and its units in metres (RoomProps.roomFromTitle)
        let xScale = (4.0 / 3.0) / RoomPlacement.aspect
        let p00 = frame.map { abs($0.projection.columns.0.x) * xScale } ?? 1
        let distance = h.x * (p00 > 0.01 ? p00 : 1)
        let metresPerUnit = distance / (frame?.depth ?? 1000)
        for i in 0..<2 {
            let hand = i < hands.count ? hands[i] : HandState()
            let pinching = hand.tracked && hand.pinching
            defer { wasPinching[i] = pinching }
            guard hand.tracked else { held[i] = nil; continue }
            let p = g.inWindow(hand.pinch)
            // Where it is on the window as you see it: from your eyes, through the pinch (at the glass, the pinch
            // itself), else from Goddard's camera
            let from = eye.flatMap { $0.z > 0.1 ? $0 : nil } ?? SIMD3(0, 0, distance)
            let ahead = from.z - p.z  // (how far in front of the eyes, towards the window)
            let at = SIMD2(from.x, from.y) + (SIMD2(p.x, p.y) - SIMD2(from.x, from.y)) * (from.z / max(ahead, 0.05))
            let near = abs(at.x) < h.y * 4 / 3 * 1.1 && abs(at.y) < h.y * 1.1 && p.z > -0.35 && ahead > 0.15
            if pinching && !wasPinching[i] {
                let label = g.startLabel
                if abs(at.x - label.center.x) < label.half.x + 0.02, abs(at.y - label.center.y) < label.half.y + 0.03,
                   p.z > -0.1, ahead > 0.15 {
                    start = true
                } else if near {
                    held[i] = p.z
                }
            }
            if !pinching { held[i] = nil }
            guard near || held[i] != nil else { continue }
            let pull = held[i].map { (p.z - $0) / metresPerUnit / 6 } ?? 0
            cursors[i] = TitleCursor(x: 160 + at.x / (h.y * 4 / 3) * 160, y: 120 - at.y / h.y * 120,
                                     pinching: held[i] != nil, pull: pull)
        }
        return (cursors, start)
    }

    func reset() { held = [nil, nil]; wasPinching = [false, false] }
}
