import ARKit
import CompositorServices
import Metal
import os
import QuartzCore
import simd
import SwiftUI

/// The immersive space's layer: stereo, the passthrough showing wherever nothing is drawn
struct RoomLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        configuration.isFoveationEnabled = false
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : .layered
    }
}

/// Draws the game into the room, behind a window floating in front of you (RoomPlacement), from each eye. Runs on
/// a thread of its own while the immersive space is open.
final class ImmersiveRenderer: @unchecked Sendable {
    private let layer: LayerRenderer
    private let game: GameRenderer
    private let frames: GameFrames
    private let link: RoomLink
    private let session = ARKitSession()
    private let world = WorldTrackingProvider()
    private let scanner = RoomScanner()
    private var placement: RoomPlacement?
    private var placedFromHead = false
    private var started: TimeInterval?
    private var drewFirstFrame = false
    static let log = Logger(subsystem: "Mario64MR", category: "Room")
    /// The room's surfaces for drawing (packed float3, metres), as the scanner last gave them
    private let roomMesh = OSAllocatedUnfairLock<(buffer: MTLBuffer?, count: Int)>(uncheckedState: (nil, 0))

    private init?(layer: LayerRenderer, device: MTLDevice, frames: GameFrames, link: RoomLink) {
        let target = GameRenderer.Target(colorFormat: layer.configuration.colorFormat,
                                         depthFormat: layer.configuration.depthFormat, room: true)
        guard let game = GameRenderer(device: device, frames: frames, target: target) else { return nil }
        self.layer = layer
        self.game = game
        self.frames = frames
        self.link = link
    }

    static func start(_ layer: LayerRenderer, host: GameHost) {
        guard let device = host.device,
              let renderer = ImmersiveRenderer(layer: layer, device: device, frames: host.output, link: host.room)
        else { return log.error("The room's renderer didn't start") }
        let thread = Thread { renderer.run() }
        thread.name = "Room"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func run() {
        // (where the head is: if tracking doesn't start, the room still shows, placed in front of where the head
        // would be, rather than staying empty)
        let tracking = Task { [session, world, scanner] in
            var providers: [any DataProvider] = WorldTrackingProvider.isSupported ? [world] : []
            if RoomScanner.isSupported,
               await session.requestAuthorization(for: [.worldSensing])[.worldSensing] == .allowed {
                providers.append(scanner.provider)
            }
            guard !providers.isEmpty else { return Self.log.info("No world tracking here") }
            var running = false
            for attempt in 1...10 where !Task.isCancelled {
                do {
                    try await session.run(providers)
                    Self.log.info("World tracking started")
                    running = true
                    break
                } catch {
                    Self.log.error("World tracking didn't start (try \(attempt)): \(error)")
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            if running, providers.contains(where: { $0 === scanner.provider }) {
                await scanner.run { [weak self] mesh in self?.useRoom(mesh) }
            }
        }
        link.update { $0.on = true }
        defer {
            link.update { $0.on = false; $0.head = nil; $0.debugRelease = nil }
            link.onClose?()
            tracking.cancel()
            session.stop()
        }
        while true {
            switch layer.state {
            case .invalidated: return
            case .paused: layer.waitUntilRunning()
            default: autoreleasepool { renderFrame() }
            }
        }
    }

    private func renderFrame() {
        guard let frame = layer.queryNextFrame() else { return }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        defer { frame.endSubmission() }
        guard let drawable = frame.queryDrawable(),
              let commands = game.queue.makeCommandBuffer() else { return }

        let time = Self.seconds(LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime))
        let anchor = world.state == .running ? world.queryDeviceAnchor(atTimestamp: time) : nil
        drawable.deviceAnchor = anchor
        // (no tracking, as in the simulator before it starts: a head standing at the origin)
        let head = anchor?.originFromAnchorTransform
            ?? simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1.5, 0, 1))
        let now = CACurrentMediaTime()
        if started == nil { started = now }
        // The first poses can be untracked, at the room's origin on the floor: place the window only from a tracked
        // head at standing or sitting height. Placed without one (after 2 s), it moves once one comes.
        let realHead = anchor.map { $0.isTracked && $0.originFromAnchorTransform.columns.3.y > 0.5 } ?? false
        if placement == nil || (!placedFromHead && realHead) {
            if realHead || !WorldTrackingProvider.isSupported || (placement == nil && now - (started ?? now) > 2) {
                // (no tracked head after 2 s, as in the simulator: in front of the pose there is, wherever it is)
                let facing = head
                let placement = RoomPlacement(facing: facing)
                self.placement = placement
                placedFromHead = realHead
                let y = head.columns.3.y, tracked = anchor?.isTracked ?? false
                Self.log.info("The window is placed (\(realHead ? "from the head" : "no tracked head yet"), head y \(y), tracked \(tracked))")
                #if DEBUG
                if !RoomScanner.isSupported {  // (the simulator: a floor and a table to try Mario out on)
                    let (room, above) = RoomMesh.standIn(window: placement, floor: facing.columns.3.y - 1.5)
                    useRoom(room)
                    link.update { $0.debugRelease = above }
                }
                #endif
            }
        }

        if let placement, let gameFrame = frames.latest() {
            let xScale = RoomPlacement.xScale(gameFrame.size)
            let level = gameFrame.draws.first { $0.kind == .world }?.projection
            let roomFromView = placement.roomFromView(projection: level, xScale: xScale)
            let viewFromRoom = roomFromView.inverse
            // The game camera and its near plane in the window's space, for the level reaching out of the window
            let windowFromView = placement.roomFromWindow.inverse * roomFromView
            let cameraInWindow = windowFromView * SIMD4(0, 0, 0, 1)
            let nearInWindow = windowFromView * SIMD4(0, 0, -RoomPlacement.near(level), 1)
            let gameCamera = SIMD4(cameraInWindow.x, cameraInWindow.y, cameraInWindow.z, nearInWindow.z)
            let up = simd_normalize(SIMD3(gameFrame.camera.columns.1.x, gameFrame.camera.columns.1.y,
                                          gameFrame.camera.columns.1.z))
            // Billboards turn to the head, in the game camera's view space (sm64unity_billboards, next tick)
            let headInView = viewFromRoom * head.columns.3
            link.update { $0.head = SIMD3(headInView.x, headInView.y, headInView.z); $0.up = up }

            let camera = gameFrame.camera
            let actorFromClip = { (draw: GameFrame.Draw) -> simd_float4x4 in
                RoomPlacement.actorFromClip(draw.projection, xScale: xScale, camera: camera)
            }
            let room = roomMesh.withLockUnchecked { $0 }
            var cache: [SIMD16<Float>: simd_float4x4] = [:]  // (most draws share a few projections)
            let roomFromClip = { (draw: GameFrame.Draw) -> simd_float4x4 in
                let c = draw.projection.columns
                let key = SIMD16(lowHalf: SIMD8(lowHalf: c.0, highHalf: c.1), highHalf: SIMD8(lowHalf: c.2, highHalf: c.3))
                if let m = cache[key] { return m }
                let m = RoomPlacement.roomFromClip(draw.projection, xScale: xScale, roomFromView: roomFromView)
                cache[key] = m
                return m
            }
            for (index, view) in drawable.views.enumerated() {
                let roomFromEye = head * view.transform
                let eye = GameRenderer.RoomEye(
                    viewProjection: drawable.computeProjection(viewIndex: index) * roomFromEye.inverse,
                    roomFromView: roomFromView,
                    roomFromWindow: placement.roomFromWindow,
                    windowFromRoom: placement.roomFromWindow.inverse,
                    eye: placement.roomFromWindow.inverse * roomFromEye.columns.3,
                    window: SIMD4(placement.halfSize.x, placement.halfSize.y, placement.skyDistance, 0),
                    up: SIMD4(up, 0),
                    camera: gameCamera)
                guard let encoder = makeEncoder(commands, drawable: drawable, view: view) else { continue }
                // The game; the room's surfaces into depth; then Mario, if he's out in the room, hidden by them
                game.encodeRoom(gameFrame, into: encoder, eye: eye, actors: false,
                                roomFromClip: roomFromClip, actorFromClip: actorFromClip)
                if gameFrame.marioOutside {
                    if let mesh = room.buffer { game.encodeRoomMesh(mesh, count: room.count, into: encoder, eye: eye) }
                    game.encodeRoom(gameFrame, into: encoder, eye: eye, actors: true,
                                    roomFromClip: roomFromClip, actorFromClip: actorFromClip)
                }
                encoder.endEncoding()
            }
            if !drewFirstFrame {
                drewFirstFrame = true
                Self.log.info("First frame in the room: \(gameFrame.draws.count) draws")
            }
        } else {
            for view in drawable.views {  // (nothing yet: clear to the passthrough)
                makeEncoder(commands, drawable: drawable, view: view)?.endEncoding()
            }
        }
        drawable.encodePresent(commandBuffer: commands)
        commands.commit()
    }

    /// A new room from the scanner: to the game (its collision, loaded on the game thread) and to the drawing
    private func useRoom(_ mesh: RoomMesh) {
        link.update { [triangles = mesh.gameTriangles()] in $0.roomTriangles = triangles }
        let corners = mesh.triangles.prefix(RoomMesh.maxTriangles * 3).flatMap { [$0.x, $0.y, $0.z] }
        let buffer = corners.isEmpty ? nil
            : game.device.makeBuffer(bytes: corners, length: corners.count * 4, options: .storageModeShared)
        roomMesh.withLockUnchecked { $0 = (buffer, corners.count / 3) }
    }

    private func makeEncoder(_ commands: MTLCommandBuffer, drawable: LayerRenderer.Drawable,
                             view: LayerRenderer.Drawable.View) -> MTLRenderCommandEncoder? {
        let map = view.textureMap
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.colorTextures[map.textureIndex]
        pass.colorAttachments[0].slice = map.sliceIndex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = drawable.depthTextures[map.textureIndex]
        pass.depthAttachment.slice = map.sliceIndex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0  // (reversed depth: far is 0)
        pass.depthAttachment.storeAction = .store
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        encoder?.setViewport(map.viewport)
        return encoder
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (s, attoseconds) = duration.components
        return Double(s) + Double(attoseconds) * 1e-18
    }
}

/// What the room tells the game thread: whether the game is drawn in the room (sm64unity_mr_geometry), and where
/// your head is for billboards to face it
final class RoomLink: @unchecked Sendable {
    struct State {
        var on = false
        var head: SIMD3<Float>?   // in the game camera's view space
        var up = SIMD3<Float>(0, 1, 0)
        /// The room's surfaces for the game to load (sm64unity_room_mesh), until it has
        var roomTriangles: [Int16]?
        /// (debug, the simulator's stand-in room) where -release drops Mario, metres
        var debugRelease: SIMD3<Float>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Called (on the room's thread) when the room closes
    var onClose: (@Sendable () -> Void)?

    func update(_ change: @Sendable (inout State) -> Void) { state.withLock(change) }
    var current: State { state.withLock { $0 } }
}
