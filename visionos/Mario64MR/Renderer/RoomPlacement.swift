import simd

/// Where the game is in the room: a window, and the game camera's view space behind it.
///
/// The game camera is placed in front of the window, where your eye would be to see exactly the game's picture
/// through it: the game's horizontal field of view just spans the window's width from there. Its view space
/// (x right, y up, looking down -z, game units) is scaled to metres and set along the window's axis, so that from
/// that point the level lines up with the flat game, and from anywhere else you see it with true parallax, as
/// through a real window. Every draw is unprojected with the projection the game drew it with
/// (sm64unity_projections), back into that view space.
struct RoomPlacement {
    /// The window's own space (metres; x right, y up, z out of the window towards you) in the room
    var roomFromWindow: simd_float4x4
    /// Half the opening's width and height, metres (16:9, the 60 fps build's picture)
    var halfSize = SIMD2<Float>(0.6, 0.3375)
    /// Game units a metre in the room, and in a window 1.2 m wide: Mario (about 160 units tall) is then about 27 cm.
    /// The level in the window grows and shrinks with it.
    static let unitsPerMetre: Float = 600
    static let aspect: Float = 16.0 / 9.0
    var scale: Float { halfSize.x / 0.6 / Self.unitsPerMetre }
    /// How far the sky is from the camera, game units (about 30 m)
    var skyDistance: Float = 18000

    /// The window `distance` metres in front of `head` (the device's pose), a little below the eyes, upright and
    /// facing it
    init(facing head: simd_float4x4, distance: Float = 1.2) {
        let position = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        var forward = -SIMD3(head.columns.2.x, 0, head.columns.2.z)
        forward = simd_length(forward) > 1e-3 ? simd_normalize(forward) : SIMD3(0, 0, -1)
        let z = -forward, y = SIMD3<Float>(0, 1, 0), x = simd_cross(y, z)
        let center = position + forward * distance - SIMD3(0, 0.1, 0)
        roomFromWindow = simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(center, 1))
    }

    /// A window `width` metres wide at `center`, upright and turned to face `eye`
    init(center: SIMD3<Float>, facing eye: SIMD3<Float>, width: Float) {
        var z = SIMD3(eye.x - center.x, 0, eye.z - center.z)
        z = simd_length(z) > 1e-3 ? simd_normalize(z) : SIMD3(0, 0, 1)
        let y = SIMD3<Float>(0, 1, 0), x = simd_cross(y, z)
        roomFromWindow = simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(center, 1))
        halfSize = SIMD2(width / 2, width / 2 / Self.aspect)
    }

    var center: SIMD3<Float> { SIMD3(roomFromWindow.columns.3.x, roomFromWindow.columns.3.y, roomFromWindow.columns.3.z) }

    /// The frame's bars' thickness around the opening, metres
    var frameThickness: Float { 0.018 + 0.012 * halfSize.x / 0.6 }

    /// The handle under the window, as visionOS's windows have: a pill in the window's plane (centre, half size)
    var handle: (center: SIMD2<Float>, half: SIMD2<Float>) {
        (SIMD2(0, -halfSize.y - frameThickness - 0.028), SIMD2(0.06, 0.0075))
    }

    /// Where "PRESS START" is on the title screen: in the window's plane, below the face (centre, half size)
    var startLabel: (center: SIMD2<Float>, half: SIMD2<Float>) {
        // (as wide as its picture is: RoomProps.labelAspect)
        (SIMD2(0, -halfSize.y * 0.86), SIMD2(halfSize.y * 0.08 * RoomProps.labelAspect, halfSize.y * 0.08))
    }

    /// The game camera's view space into the room, for a frame whose level was drawn with `projection` (as
    /// GameFrame keeps it) in a window `aspect` wide (gfx_pc.c narrows x by (4/3) / aspect after projecting)
    func roomFromView(projection: simd_float4x4?, xScale: Float) -> simd_float4x4 {
        // From where the game's horizontal field of view spans the window: tan(half) = 1 / (xScale * P[0][0])
        let p00 = projection.map { abs($0.columns.0.x) * xScale } ?? 1.36
        let distance = halfSize.x * (p00 > 0.01 ? p00 : 1.36)
        let translate = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, distance, 1))
        let scaling = simd_float4x4(diagonal: SIMD4(scale, scale, scale, 1))
        return roomFromWindow * translate * scaling
    }

    /// The x narrowing of a game picture `size` pixels wide and high (gfx_adjust_x_for_aspect_ratio)
    static func xScale(_ size: SIMD2<Int32>) -> Float {
        (4.0 / 3.0) / (Float(size.x) / Float(size.y))
    }

    /// A draw's clip space into the room: its projection and the x narrowing undone, then roomFromView
    static func roomFromClip(_ projection: simd_float4x4, xScale: Float, roomFromView: simd_float4x4) -> simd_float4x4 {
        let narrowing = simd_float4x4(diagonal: SIMD4(xScale, 1, 1, 1))
        return roomFromView * (narrowing * projection).inverse
    }

    /// Mario's draws while he's out in the room: his clip space back into the game camera's view space, on into
    /// the room's game coordinates (the camera undone), and to metres
    static func actorFromClip(_ projection: simd_float4x4, xScale: Float, camera: simd_float4x4) -> simd_float4x4 {
        let narrowing = simd_float4x4(diagonal: SIMD4(xScale, 1, 1, 1))
        let metres = simd_float4x4(diagonal: SIMD4(SIMD3(repeating: 1 / unitsPerMetre), 1))
        return metres * camera.inverse * (narrowing * projection).inverse
    }
}
