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
    private let handTracker = HandTracker()
    private let gazePinches = GazePinches()
    private let planeFinder = PlaneFinder()
    private let props: RoomProps
    /// The cartridge, and the window it opens into (made at the first frame, in front of you)
    private var cartridge: Cartridge?
    /// The level as a diorama on a table, while it is one
    private var diorama: Diorama?
    /// (the simulator's stand-in room's planes)
    private var standInPlanes: [RoomPlane] = []
    private var lastTime: TimeInterval?
    private var startTime: TimeInterval?
    private var placedFromHead = false
    private var loggedRoom = false
    private var started: TimeInterval?
    private var drewFirstFrame = false
    static let log = Logger(subsystem: "Mario64MR", category: "Room")
    /// The room's surfaces for drawing (packed float3, metres), as the scanner last gave them
    private let roomMesh = OSAllocatedUnfairLock<(buffer: MTLBuffer?, count: Int)>(uncheckedState: (nil, 0))

    private init?(layer: LayerRenderer, device: MTLDevice, frames: GameFrames, link: RoomLink) {
        let target = GameRenderer.Target(colorFormat: layer.configuration.colorFormat,
                                         depthFormat: layer.configuration.depthFormat, room: true)
        guard let game = GameRenderer(device: device, frames: frames, target: target),
              let props = RoomProps(device: device, library: game.library, colorFormat: target.colorFormat,
                                    depthFormat: target.depthFormat) else { return nil }
        self.props = props
        self.layer = layer
        self.game = game
        self.frames = frames
        self.link = link
    }

    static func start(_ layer: LayerRenderer, host: GameHost) {
        guard let device = host.device,
              let renderer = ImmersiveRenderer(layer: layer, device: device, frames: host.output, link: host.room)
        else { return log.error("The room's renderer didn't start") }
        Task { @MainActor in renderer.gazePinches.listen(to: layer) }
        let thread = Thread { renderer.run() }
        thread.name = "Room"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func run() {
        // (where the head is: if tracking doesn't start, the room still shows, placed in front of where the head
        // would be, rather than staying empty)
        let tracking = Task { [session, world, scanner, handTracker, planeFinder] in
            var providers: [any DataProvider] = WorldTrackingProvider.isSupported ? [world] : []
            let wanted: [ARKitSession.AuthorizationType] = [.worldSensing, .handTracking]
            let allowed = await session.requestAuthorization(for: wanted)
            let sensing = allowed[.worldSensing] == .allowed
            if RoomScanner.isSupported, sensing { providers.append(scanner.provider) }
            if PlaneFinder.isSupported, sensing { providers.append(planeFinder.provider) }
            if HandTracker.isSupported, allowed[.handTracking] == .allowed { providers.append(handTracker.provider) }
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
            guard running else { return }
            await withTaskGroup(of: Void.self) { group in
                if providers.contains(where: { $0 === scanner.provider }) {
                    group.addTask { await scanner.run { [weak self] mesh in self?.useRoom(mesh) } }
                }
                if providers.contains(where: { $0 === planeFinder.provider }) {
                    group.addTask { await planeFinder.run() }
                }
            }
        }
        link.update { $0.on = true }
        defer {
            link.update { $0.on = false; $0.head = nil; $0.facing = nil; $0.debugRelease = nil; $0.geometry = nil; $0.hands = [] }
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
        // The first poses can be untracked, at the room's origin on the floor: place the cartridge only from a
        // tracked head at standing or sitting height. Placed without one (after 2 s), it moves once one comes, if
        // it isn't open or in a hand by then.
        let realHead = anchor.map { $0.isTracked && $0.originFromAnchorTransform.columns.3.y > 0.5 } ?? false
        // (with no cartridge, the window opens at once, so it moves too until a hand takes it)
        let movable = cartridge.map { (!$0.isOpen || !Cartridge.enabled) && $0.holding.isEmpty } ?? true
        if cartridge == nil || (!placedFromHead && realHead && movable) {
            if realHead || !WorldTrackingProvider.isSupported || (cartridge == nil && now - (started ?? now) > 2) {
                // (no tracked head after 2 s, as in the simulator: in front of the pose there is, wherever it is)
                let facing = head
                let cartridge = Cartridge(facing: facing)
                self.cartridge = cartridge
                if !Cartridge.enabled { cartridge.open(RoomPlacement(facing: facing)) }
                if startTime == nil { startTime = time }
                placedFromHead = realHead
                let y = head.columns.3.y, tracked = anchor?.isTracked ?? false
                Self.log.info("The \(Cartridge.enabled ? "cartridge" : "window") is placed (\(realHead ? "from the head" : "no tracked head yet"), head y \(y), tracked \(tracked))")
                #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if Cartridge.enabled, ["-open", "-carry", "-diorama"].contains(where: arguments.contains) {
                    cartridge.open(RoomPlacement(facing: facing))
                }
                if !RoomScanner.isSupported {  // (the simulator: a floor and a table to try Mario out on)
                    let (room, above, planes) = RoomMesh.standIn(window: RoomPlacement(facing: facing),
                                                                  floor: facing.columns.3.y - 1.5)
                    useRoom(room)
                    standInPlanes = planes
                    link.update { $0.debugRelease = above }
                }
                #endif
            }
        }
        guard let cartridge else {
            for view in drawable.views {  // (nothing yet: clear to the passthrough)
                makeEncoder(commands, drawable: drawable, view: view)?.endEncoding()
            }
            drawable.encodePresent(commandBuffer: commands)
            commands.commit()
            return
        }

        // Your hands: on the cartridge or the window's frame first; the rest go to the game
        let eyePosition = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let gameFrame = frames.latest()
        var hands = handTracker.update(at: time)
        var gazes = gazePinches.take()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-cart") {
            hands = scriptedHands(time - (startTime ?? time), cartridge: cartridge, eye: eyePosition,
                                  title: gameFrame?.title != nil)
        }
        if ProcessInfo.processInfo.arguments.contains("-diorama") {
            (hands, gazes) = scriptedDioramaHands(time, cartridge: cartridge, stage: link.current.stage,
                                                  eye: eyePosition)
        }
        #endif
        let dt = Float(lastTime.map { time - $0 } ?? 0)
        lastTime = time
        let planes = planeFinder.current + standInPlanes
        let stage = link.current.stage
        // Held by its lower part over a table (or the floor): the circle shows where it would go down
        let low = cartridge.heldLow
        let circle = low.flatMap { Self.circle(under: $0.bottom, planes: planes) }
        cartridge.update(hands: hands, gazes: gazes, eye: eyePosition, planes: planes, floor: min(0, head.columns.3.y - 1.5), dt: dt)
        if let low, let circle, stage == 3, let gameFrame, !cartridge.holding.contains(low.hand),
           cartridge.isOpen, cartridge.heldLow == nil {
            // Let go over it: the level rises out of it
            diorama = Diorama(center: circle, eye: eyePosition, camera: gameFrame.camera, mario: gameFrame.mario,
                              levelCenter: gameFrame.levelCenter())
            cartridge.enterDiorama()
        }
        if let diorama {
            let width = cartridge.window.halfSize.x * 2
            diorama.update(hands: hands, gazes: gazes, cameraStick: GamePad.cameraStick(),
                           recenter: GamePad.cameraStickPressed(), mario: gameFrame?.mario, dt: dt)
            if stage != 3 {  // (left the course: the window back, standing on the base)
                let h = cartridge.window.halfSize.y
                cartridge.leaveDiorama(RoomPlacement(center: diorama.center + SIMD3(0, h + 0.05, 0),
                                                     facing: eyePosition, width: width), hand: nil, grip: .zero)
                self.diorama = nil
            }
            for i in hands.indices { hands[i].pinching = false }  // (hands are for the base, not the game)
        }
        for i in cartridge.holding where i < hands.count { hands[i].pinching = false }
        let placement = cartridge.window
        let w = placement.roomFromWindow.columns.3
        scanner.focus = SIMD3(w.x, w.y, w.z)

        let xScale = gameFrame.map { RoomPlacement.xScale($0.size) } ?? 0.75
        let level = gameFrame?.draws.first { $0.kind == .world }?.projection
        let camera = gameFrame?.camera ?? matrix_identity_float4x4
        let roomFromWorld = diorama?.roomFromWorld()
        let roomFromView = roomFromWorld.map { $0 * camera.inverse }
            ?? placement.roomFromView(projection: level, xScale: xScale)
        let viewFromRoom = roomFromView.inverse
        // The game camera and its near plane in the window's space, for the level reaching out of the window
        let windowFromView = placement.roomFromWindow.inverse * roomFromView
        let cameraInWindow = windowFromView * SIMD4(0, 0, 0, 1)
        let nearInWindow = windowFromView * SIMD4(0, 0, -RoomPlacement.near(level), 1)
        let gameCamera = SIMD4(cameraInWindow.x, cameraInWindow.y, cameraInWindow.z, nearInWindow.z)
        let up = simd_normalize(SIMD3(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z))
        // Billboards turn to the head, in the game camera's view space (sm64unity_billboards, next tick)
        let headInView = viewFromRoom * head.columns.3
        let geometry = RoomGeometry(roomFromView: roomFromView, windowFromRoom: placement.roomFromWindow.inverse,
                                    halfSize: placement.halfSize, open: cartridge.isOpen, diorama: diorama != nil,
                                    startLabel: placement.startLabel)
        // The way back towards you from where you look, level (the stick, out in the room: sm64unity_room_facing).
        // Looking down, the head's up points ahead, and looking up, behind
        let back = head.columns.2, headUp = head.columns.1
        let levelBack = back - headUp * (back.y >= 0 ? 1 : -1)
        let lookForward = -SIMD3(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        let dioramaForward = diorama?.forwardInWorld(eyeForward: lookForward)
        link.update { [hands] in
            $0.head = SIMD3(headInView.x, headInView.y, headInView.z); $0.up = up
            $0.facing = SIMD2(levelBack.x, levelBack.z)
            $0.geometry = geometry; $0.hands = hands; $0.dioramaForward = dioramaForward
        }

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
            // Open: the game through the window (or the title screen's face), in its frame. Closed: the cartridge.
            // Then the room's surfaces into depth and Mario, if he's out in the room, hidden by them
            if let diorama, let roomFromWorld {
                if let gameFrame {
                    game.encodeDiorama(gameFrame, into: encoder, eye: eye, roomFromWorld: roomFromWorld,
                                       table: diorama.table, xScale: xScale)
                }
            } else if cartridge.isOpen {
                props.encodeFrame(placement, into: encoder, eye: eye)
                if let gameFrame, let title = gameFrame.title {
                    props.encodeTitle(title, window: placement, time: time - (startTime ?? 0), into: encoder, eye: eye)
                } else if let gameFrame {
                    game.encodeRoom(gameFrame, into: encoder, eye: eye, actors: false,
                                    roomFromClip: roomFromClip, actorFromClip: actorFromClip)
                }
            } else {
                props.encodeCartridge(cartridge.pose, into: encoder, eye: eye)
            }
            if diorama == nil, let gameFrame, gameFrame.marioOutside {
                if let mesh = room.buffer { game.encodeRoomMesh(mesh, count: room.count, into: encoder, eye: eye) }
                game.encodeRoom(gameFrame, into: encoder, eye: eye, actors: true,
                                roomFromClip: roomFromClip, actorFromClip: actorFromClip)
            }
            // The handle, and where the window will go down, last: they're blended (into depth only where they
            // show), so whatever came after them (the frame, the level reaching out of the window) would paint over
            // their soft edges
            if diorama == nil, cartridge.isOpen {
                props.encodeHandle(placement, held: !cartridge.holding.isEmpty, into: encoder, eye: eye)
            }
            if diorama == nil, cartridge.isOpen, let circle {
                let glow = Float(0.75 + 0.25 * sin(time * 6))
                props.encodeCircle(at: circle, radius: Diorama.radius, glow: glow, into: encoder, eye: eye)
            }
            encoder.endEncoding()
        }
        if !drewFirstFrame, let gameFrame {
            drewFirstFrame = true
            Self.log.info("First frame in the room: \(gameFrame.draws.count) draws")
        }
        drawable.encodePresent(commandBuffer: commands)
        commands.commit()
    }

    /// The point on a plane under `p` (the window's bottom edge), if one is near enough below it to put it down on
    private static func circle(under p: SIMD3<Float>, planes: [RoomPlane]) -> SIMD3<Float>? {
        let below = planes.filter { $0.height <= p.y + 0.05 && $0.height >= p.y - 0.35 && $0.contains(SIMD2(p.x, p.z)) }
        return below.max { $0.height < $1.height }.map { SIMD3(p.x, $0.height, p.z) }
    }

    #if DEBUG
    /// With -diorama (and -demo, to get into a course): once in a course, a hand in your lap pinches looking at the
    /// window's handle and moves it a little; then a hand takes the window by its lower
    /// part, puts it down over the stand-in room's counter, and lets go; then slides the base, turns it with two
    /// hands, and pinches from afar while looking at it to move it back and up
    private var dioramaSince: TimeInterval?
    private var dioramaFrom: SIMD3<Float>?
    private var slideFrom: SIMD3<Float>?
    private var gazeFrom: SIMD3<Float>?
    private var handleFrom: SIMD3<Float>?

    private func scriptedDioramaHands(_ time: TimeInterval, cartridge: Cartridge, stage: Int32,
                                      eye: SIMD3<Float>) -> ([HandState], [GazePinch]) {
        let (hands, gaze) = scriptedDioramaInput(time, cartridge: cartridge, stage: stage, eye: eye)
        return (hands, gaze.map { [$0] } ?? [])
    }

    private func scriptedDioramaInput(_ time: TimeInterval, cartridge: Cartridge, stage: Int32,
                                      eye: SIMD3<Float>) -> ([HandState], GazePinch?) {
        func hand(_ p: SIMD3<Float>, pinching: Bool) -> HandState {
            var h = HandState(tracked: true)
            h.pinch = p; h.reach = p; h.pinching = pinching
            h.palm = p + SIMD3(0, -0.05, 0.08)
            return h
        }
        if dioramaSince == nil {
            guard stage == 3 else { return ([], nil) }
            dioramaSince = time
        }
        let s = time - dioramaSince! - 4
        let w = cartridge.window
        if s > -3 && s < -1.5 {  // looking at the handle, pinch with a hand in your lap and move it 5 cm right
            if handleFrom == nil { handleFrom = eye + SIMD3(0.15, -0.45, -0.25) }
            let k = Float(min(max((s + 2.8) / 1, 0), 1))
            let p = handleFrom! + SIMD3(0.05 * k, 0, 0), pinching = s > -2.9 && s < -1.6
            let handle = w.roomFromWindow.transform(SIMD3(w.handle.center, 0))
            let gaze = pinching ? GazePinch(id: 2_000_000, began: true, origin: eye,
                                            direction: simd_normalize(handle - eye), hand: 1, position: p) : nil
            return ([HandState(), hand(p, pinching: pinching)], gaze)
        }
        guard s > 0, let above = link.current.debugRelease else { return ([], nil) }
        if s < 2.8 {
            if dioramaFrom == nil { dioramaFrom = w.roomFromWindow.transform(SIMD3(0, -w.halfSize.y - 0.015, 0)) }
            let to = above - SIMD3(0, 0.1 + 0.015, 0)  // (the window's bottom 15 cm over the counter)
            let k = Float(min(max((s - 0.5) / 2, 0), 1))
            return ([hand(dioramaFrom! + (to - dioramaFrom!) * k, pinching: s > 0.3 && s < 2.6), HandState()], nil)
        }
        guard let diorama else { return ([], nil) }
        let c = diorama.center, r = Diorama.radius
        if s > 6 && s < 8 {  // slide it 10 cm to the right
            let k = Float(min(max((s - 6.3) / 1.2, 0), 1))
            if slideFrom == nil { slideFrom = c }
            let right = SIMD3<Float>(1, 0, 0)
            return ([HandState(), hand(slideFrom! + right * (r * 0.9 + 0.1 * k) + SIMD3(0, 0.01, 0), pinching: s > 6.2)], nil)
        }
        if s > 10 && s < 12.5 {  // turn it 40° with two hands
            let a = Float(min(max((s - 10.4) / 1.6, 0), 1)) * 0.7
            let d = SIMD3(sin(a), 0, cos(a)) * r * 0.9
            return ([hand(c - d + SIMD3(0, 0.01, 0), pinching: s > 10.3), hand(c + d + SIMD3(0, 0.01, 0), pinching: s > 10.3)], nil)
        }
        if s > 14 && s < 16.5 {  // looking at it, pinch with a hand in your lap: 10 cm back left, and 10 cm up
            if gazeFrom == nil { gazeFrom = eye + SIMD3(0.15, -0.45, -0.25) }
            let k = Float(min(max((s - 14.4) / 1.2, 0), 1))
            let p = gazeFrom! + SIMD3(-0.1 * k, 0.1 * k, 0), pinching = s > 14.3 && s < 16.2
            let toward = simd_normalize(SIMD3(c.x, c.y + 0.2, c.z) - eye)
            let gaze = pinching ? GazePinch(id: 1_000_000, began: true, origin: eye, direction: toward,
                                            hand: 1, position: p) : nil
            return ([HandState(), hand(p, pinching: pinching)], gaze)
        }
        return ([], nil)
    }

    /// With -cart (debug builds, for the simulator, which has no hands): two hands take the cartridge in front of
    /// you at 1 s and pull it open into a window 1.2 m wide, 1.2 m away. On the title screen they take Mario's
    /// face by the nose and an ear and pull, let go, and pinch "PRESS START".
    private var titleSince: TimeInterval?

    private func scriptedHands(_ t: TimeInterval, cartridge: Cartridge, eye: SIMD3<Float>, title: Bool) -> [HandState] {
        func hand(_ p: SIMD3<Float>, pinching: Bool) -> HandState {
            var h = HandState(tracked: true)
            h.pinch = p; h.reach = p; h.pinching = pinching
            h.palm = p + SIMD3(0, -0.05, 0.08)
            return h
        }
        if t < 3.4 {
            guard t > 1 else { return [] }
            if !cartridge.isOpen || t < 3.0 {
                let center = cartridge.isOpen ? cartridge.window.center : cartridge.center
                let pose = cartridge.isOpen ? cartridge.window.roomFromWindow : cartridge.pose
                let across = simd_normalize(SIMD3(pose.columns.0.x, 0, pose.columns.0.z))
                // From the cartridge's ends out to ±0.35 m, 1.2 m in front of you, 10 cm below the eyes
                var forward = SIMD3(center.x - eye.x, 0, center.z - eye.z)
                forward = simd_length(forward) > 1e-3 ? simd_normalize(forward) : SIMD3(0, 0, -1)
                let target = eye + forward * 1.2 - SIMD3(0, 0.1, 0)
                let start = cartridgeStart ?? cartridge.center
                if cartridgeStart == nil { cartridgeStart = start }
                let k = Float(min(max((t - 1.5) / 1.5, 0), 1))
                let mid = start + (target - start) * k
                let half = 0.05 + (0.35 - 0.05) * k
                return [hand(mid - across * half, pinching: t >= 1.5), hand(mid + across * half, pinching: t >= 1.5)]
            }
            return []
        }
        guard title, cartridge.isOpen else { titleSince = nil; return [] }
        if titleSince == nil { titleSince = t }
        let s = t - titleSince!
        let w = cartridge.window.roomFromWindow, h = cartridge.window.halfSize
        func at(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { w.transform(SIMD3(x, y, z)) }
        if s > 2 && s < 6 {
            let k = Float(min(max((s - 2.5) / 2, 0), 1))
            let pinching = s >= 2.5 && s < 5
            return [hand(at(-h.y * 0.45 - 0.12 * k, h.y * 0.05, 0.02 + 0.1 * k), pinching: pinching),
                    hand(at(0.02 + 0.1 * k, -h.y * 0.05, 0.05 + 0.25 * k), pinching: pinching)]
        }
        if s > 7 && s < 8 {
            let label = cartridge.window.startLabel
            return [hand(at(label.center.x, label.center.y, 0.01), pinching: s > 7.4), HandState()]
        }
        return []
    }
    private var cartridgeStart: SIMD3<Float>?
    #endif

    /// A new room from the scanner: to the game (its collision, loaded on the game thread) and to the drawing
    private func useRoom(_ mesh: RoomMesh) {
        let triangles = mesh.gameTriangles()
        if !loggedRoom {
            // (how much of the room the game has, and how much of it is floor: tops of things, facing up)
            var floors = 0, i = 0
            while i + 8 < triangles.count {
                let v = (0..<9).map { Float(triangles[i + $0]) }
                let n = simd_cross(SIMD3(v[3] - v[0], v[4] - v[1], v[5] - v[2]), SIMD3(v[6] - v[0], v[7] - v[1], v[8] - v[2]))
                if simd_normalize(n).y > 0.7 { floors += 1 }
                i += 9
            }
            Self.log.info("The room: \(mesh.triangles.count / 3) triangles scanned, \(triangles.count / 9) to the game, \(floors) of them floors")
            loggedRoom = triangles.count / 9 > 1000
        }
        link.update { $0.roomTriangles = triangles }
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
        /// The way back towards your head from where you look, level, in the room (x, z)
        var facing: SIMD2<Float>?
        /// The room's surfaces for the game to load (sm64unity_room_mesh), until it has
        var roomTriangles: [Int16]?
        /// (debug, the simulator's stand-in room) where -carry's hand puts Mario, metres
        var debugRelease: SIMD3<Float>?
        /// The window and game camera in the room, and your hands, for MarioCarrier
        var geometry: RoomGeometry?
        var hands: [HandState] = []
        /// (from the game) its stage: sm64unity_stage
        var stage: Int32 = 0
        /// In a diorama: your forward in the game's world, for the stick to move Mario the way you look
        var dioramaForward: SIMD3<Float>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Called (on the room's thread) when the room closes
    var onClose: (@Sendable () -> Void)?

    func update(_ change: @Sendable (inout State) -> Void) { state.withLock(change) }
    var current: State { state.withLock { $0 } }
}
