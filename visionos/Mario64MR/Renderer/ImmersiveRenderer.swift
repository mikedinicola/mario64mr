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
        // (what you look at: a tracking area's value a pixel, for the system's hover effect)
        let tracking = capabilities.supportedTrackingAreasFormats
        if let format = tracking.first(where: { $0 == .r16Uint }) ?? tracking.first {
            configuration.trackingAreasFormat = format
            configuration.trackingAreasUsage = [.renderTarget, .shaderRead]  // (the compositor reads it: it must)
        }
        // The options: foveation (on at any level) as the room opens; room for the resolution's 150%
        let foveation = capabilities.supportsFoveation && GameOptions.savedGraphics.foveation
        configuration.isFoveationEnabled = foveation
        let layouts = capabilities.supportedLayouts(options: foveation ? [.foveationEnabled] : [])
        configuration.layout = layouts.contains(.dedicated) ? .dedicated : .layered
        // (the simulator has none: its default isn't a number, and a max aborts the layer)
        let quality = capabilities.defaultRenderQuality.rawValue
        let supported = quality.isFinite && quality > 0 && quality <= 1
        Self.defaultQuality.withLock { $0 = supported ? quality : nil }
        if supported { configuration.maxRenderQuality = LayerRenderer.RenderQuality(rawValue: 1) }
    }

    /// The headset's own render quality (the options' 100%), if it has one
    static let defaultQuality = OSAllocatedUnfairLock<Float?>(initialState: nil)

    /// The options' resolution (0.7 to 1.5) as a render quality: 100% the default, 70% the least, 150% the most
    static func quality(_ resolution: Float) -> Float? {
        guard let base = defaultQuality.withLock({ $0 }) else { return nil }
        return resolution >= 1 ? base + (1 - base) * min((resolution - 1) / 0.5, 1)
            : base * max((resolution - 0.7) / 0.3, 0)
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
    private let controllerTracker = ControllerTracker()
    private let planeFinder = PlaneFinder()
    private let props: RoomProps
    /// The game's flat picture of its level, each frame, for what it has between its camera and the window (painted
    /// on the glass: RoomProps.encodeWindowPicture)
    private let flat: GameRenderer
    private var windowPicture: (color: MTLTexture, depth: MTLTexture)?
    /// The game frame the window's picture is of (its number and vertices) and the anisotropy it was drawn with: a
    /// game frame lasts 1½ of the headset's (60 a second to 90), and drawn again it would be the same picture
    private var windowPictureOf: (number: UInt32, vertices: ObjectIdentifier?, anisotropy: Int)?
    /// The cartridge, and the window it opens into (made at the first frame, in front of you)
    private var cartridge: Cartridge?
    /// The level as a diorama on a table, while it is one
    private var diorama: Diorama?
    /// Mario 128 in your room, opened for it (RoomLink.mario128): no cartridge nor window, the stage on your table
    private var mario128Mode = false
    private var mario128: Mario128Stage?
    #if DEBUG
    private var mario128Since: TimeInterval?
    private var mario128From: SIMD3<Float>?
    #endif
    /// The room as the scanner last gave it (metres), for the stage put down in it
    private let latestRoom = OSAllocatedUnfairLock<RoomMesh?>(uncheckedState: nil)
    /// The treasure chest by the window, and what was taken out of it this frame
    private let chest = TreasureChest()
    /// (the simulator's stand-in room's planes)
    private var standInPlanes: [RoomPlane] = []
    private var lastTime: TimeInterval?
    private var startTime: TimeInterval?
    private var placedFromHead = false
    /// Opened again out of a diorama (the Digital Crown, RoomLink.reopenWidth): the window open from the start,
    /// this wide, in front of you
    private var reopenWidth: Float?
    private var loggedRoom = false
    private var started: TimeInterval?
    private var drewFirstFrame = false
    static let log = Logger(subsystem: "Mario64MR", category: "Room")
    /// (-perf: its frames' times in the console, GameHost's PerfLog)
    private let perf = PerfLog(name: "room")
    /// The options' graphics applied now
    private var graphics: GameOptions.Graphics?
    /// The views' MSAA targets (memoryless), resolved into the drawable's
    private var multisample: [Int: (color: MTLTexture, depth: MTLTexture)] = [:]
    /// The room's surfaces for drawing (packed float3, metres), as the scanner last gave them
    private let roomMesh = OSAllocatedUnfairLock<(buffer: MTLBuffer?, count: Int)>(uncheckedState: (nil, 0))

    private init?(layer: LayerRenderer, device: MTLDevice, frames: GameFrames, link: RoomLink) {
        let target = GameRenderer.Target(colorFormat: layer.configuration.colorFormat,
                                         depthFormat: layer.configuration.depthFormat, room: true)
        guard let game = GameRenderer(device: device, frames: frames, target: target),
              let flat = GameRenderer(device: device, frames: frames, target: .flat),
              let props = RoomProps(device: device, library: game.library, colorFormat: target.colorFormat,
                                    depthFormat: target.depthFormat) else { return nil }
        self.props = props
        self.flat = flat
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
        let tracking = Task { [session, world, scanner, handTracker, planeFinder, controllerTracker] in
            var providers: [any DataProvider] = WorldTrackingProvider.isSupported ? [world] : []
            var wanted: [ARKitSession.AuthorizationType] = [.worldSensing, .handTracking]
            if ControllerTracker.isSupported { wanted += AccessoryTrackingProvider.requiredAuthorizations }
            let allowed = await session.requestAuthorization(for: wanted)
            let sensing = allowed[.worldSensing] == .allowed
            if RoomScanner.isSupported, sensing { providers.append(scanner.provider) }
            if PlaneFinder.isSupported, sensing { providers.append(planeFinder.provider) }
            if HandTracker.isSupported, allowed[.handTracking] == .allowed { providers.append(handTracker.provider) }
            if let controllers = controllerTracker.makeProvider() { providers.append(controllers) }
            // (controllers paired later are tracked as they come)
            SpatialControllers.shared.onChange = { accessories in
                Task { await controllerTracker.track(accessories, in: session) }
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
        reopenWidth = link.current.reopenWidth
        mario128Mode = link.current.mario128
        link.update { $0.on = true; $0.reopenWidth = nil }
        defer {
            // The Digital Crown in a diorama: back to the window (the room opens again), not out of the room
            let width = diorama != nil ? cartridge.map { $0.window.halfSize.x * 2 } : nil
            link.update { $0.reopenWidth = width }
            link.update { $0.mario128 = false; $0.stagePlace = nil }
            link.update { $0.on = false; $0.head = nil; $0.facing = nil; $0.debugRelease = nil; $0.geometry = nil; $0.hands = []; $0.picks = []; $0.chest = nil }
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
        let cpuStart = PerfLog.now
        // (usually one; a second while the view is being recorded or shared, at its own quality and without
        // foveation: each gets the same frame)
        let drawables = frame.queryDrawables()
        // None as the room closes (the Digital Crown): the frame isn't valid, and ending its submission aborts
        // the app
        guard let drawable = drawables.first else { return }
        defer { frame.endSubmission() }
        guard let commands = game.queue.makeCommandBuffer() else { return }

        applyOptions()
        let time = Self.seconds(LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime))
        let anchor = world.state == .running ? world.queryDeviceAnchor(atTimestamp: time) : nil
        for drawable in drawables { drawable.deviceAnchor = anchor }
        // (no tracking, as in the simulator before it starts: a head standing at the origin)
        let head = anchor?.originFromAnchorTransform
            ?? simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1.5, 0, 1))
        let now = CACurrentMediaTime()
        if started == nil { started = now }
        // The first poses can be untracked, at the room's origin on the floor: place the cartridge only from a
        // tracked head at standing or sitting height. Placed without one (after 2 s), it moves once one comes, if
        // it isn't open or in a hand by then.
        let realHead = anchor.map { $0.isTracked && $0.originFromAnchorTransform.columns.3.y > 0.5 } ?? false
        if mario128Mode {
            renderMario128(drawables, commands: commands, head: head, realHead: realHead, time: time, now: now)
            return
        }
        // (with no cartridge, the window opens at once, so it moves too until a hand takes it)
        let movable = cartridge.map { (!$0.isOpen || !Cartridge.enabled || reopenWidth != nil) && $0.holding.isEmpty }
            ?? true
        if cartridge == nil || (!placedFromHead && realHead && movable) {
            if realHead || !WorldTrackingProvider.isSupported || (cartridge == nil && now - (started ?? now) > 2) {
                // (no tracked head after 2 s, as in the simulator: in front of the pose there is, wherever it is)
                let facing = head
                let cartridge = Cartridge(facing: facing)
                self.cartridge = cartridge
                if let width = reopenWidth {
                    let eye = SIMD3(facing.columns.3.x, facing.columns.3.y, facing.columns.3.z)
                    cartridge.open(RoomPlacement(center: RoomPlacement(facing: facing).center, facing: eye, width: width))
                    if realHead { reopenWidth = nil }  // (until then it moves to the head when one comes)
                } else if !Cartridge.enabled {
                    cartridge.open(RoomPlacement(facing: facing))
                }
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
            for (slot, drawable) in drawables.enumerated() {
                for view in drawable.views {  // (nothing yet: clear to the passthrough)
                    makeEncoder(commands, drawable: drawable, slot: slot, view: view)?.endEncoding()
                }
                drawable.encodePresent(commandBuffer: commands)
            }
            commands.commit()
            return
        }

        // Your hands: on the cartridge or the window's frame first; the rest go to the game
        let eyePosition = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let gameFrame = frames.latest()
        var hands = handTracker.update(at: time)
        var gazes = gazePinches.take()
        // A Sense controller in a hand stands in for it, its grip the pinch
        while hands.count < 2 { hands.append(HandState()) }
        var controls: [Int: ControllerControl] = [:]
        for (side, hand, control) in controllerTracker.hands(at: time) {
            hands[side] = hand
            controls[side] = control
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-cart") {
            hands = scriptedHands(time - (startTime ?? time), cartridge: cartridge, eye: eyePosition,
                                  title: gameFrame?.title != nil)
        }
        if ProcessInfo.processInfo.arguments.contains("-diorama") {
            (hands, gazes) = scriptedDioramaHands(time, cartridge: cartridge, stage: link.current.stage,
                                                  eye: eyePosition)
        }
        if ProcessInfo.processInfo.arguments.contains("-chest") {
            (hands, gazes) = scriptedChestInput(time, stage: link.current.stage, eye: eyePosition)
        }
        #endif
        let dt = Float(lastTime.map { time - $0 } ?? 0)
        lastTime = time
        let planes = planeFinder.current + standInPlanes
        let stage = link.current.stage
        // The treasure chest by the window: in a course, the window open, Mario playing (not in a cutscene) (looks it
        // used aren't the frame's)
        chest.spawnable = link.current.spawnable
        let showChest = cartridge.isOpen && diorama == nil && stage == 3 && gameFrame?.title == nil && chest.spawnable != 0
        if !showChest, chest.isOpen { chest.close() }
        let taken = chest.update(window: cartridge.window, show: showChest, hands: hands, gazes: gazes,
                                 eye: eyePosition, time: time, dt: dt)
        gazes.removeAll { taken.usedGazes.contains($0.id) }
        let picks = taken.picks
        let chestPose = chest.gamePose
        // Held by its lower part over a table (or the floor): the circle shows where it would go down
        let low = cartridge.heldLow
        let circle = low.flatMap { Self.circle(under: $0.bottom, planes: planes) }
        // (a pinch that began on one of the chest's tiles isn't the window's)
        var windowHands = hands
        for i in windowHands.indices where i < 2 && chest.claimed[i] { windowHands[i].pinching = false }
        cartridge.update(hands: windowHands, gazes: gazes, eye: eyePosition, planes: planes, floor: min(0, head.columns.3.y - 1.5),
                         dt: dt, controls: controls)
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
                           recenter: GamePad.cameraStickPressed(), cycleZoom: GamePad.moveStickPressed(), mario: gameFrame?.mario, dt: dt, controls: controls)
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
        // What the level has between the game camera and the window: the game's flat picture of it, to paint on
        // the glass where its nearest surface is nearer than the window (in its depth, `nearer`). And a centimetre
        // past it (in a window 1.2 m wide): the level is cut off at the window a pixel at a time, the painting a
        // pixel of its picture at a time, and along where the two meet some pixels would be neither, a thin gap
        var nearPicture: (color: MTLTexture, depth: MTLTexture, nearer: Float)?
        if diorama == nil, cartridge.isOpen, let gameFrame, gameFrame.title == nil, let level,
           let picture = renderWindowPicture(gameFrame, commands: commands) {
            let cameraInWindow = placement.roomFromWindow.inverse * roomFromView * SIMD4<Float>(0, 0, 0, 1)
            let overlap = 0.01 * placement.halfSize.x / 0.6
            let clip = level * SIMD4(0, 0, -(cameraInWindow.z + overlap) / placement.scale, 1)
            if clip.w > 0 { nearPicture = (picture.color, picture.depth, (clip.z / clip.w + 1) / 2) }
        }
        let up = simd_normalize(SIMD3(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z))
        // Billboards turn to the head, in the game camera's view space (sm64unity_billboards, next tick)
        let headInView = viewFromRoom * head.columns.3
        let geometry = RoomGeometry(roomFromView: roomFromView, windowFromRoom: placement.roomFromWindow.inverse,
                                    halfSize: placement.halfSize, open: cartridge.isOpen, diorama: diorama != nil,
                                    startLabel: placement.startLabel, worldFromRoom: roomFromWorld?.inverse)
        // The way back towards you from where you look, level (the stick, out in the room: sm64unity_room_facing).
        // Looking down, the head's up points ahead, and looking up, behind
        let back = head.columns.2, headUp = head.columns.1
        let levelBack = back - headUp * (back.y >= 0 ? 1 : -1)
        let lookForward = -SIMD3(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        // (the controllers holding something: their sticks and triggers aren't the game's)
        let busy = cartridge.holding.union(diorama?.holding ?? []).intersection(controls.keys)
        let dioramaForward = diorama?.forwardInWorld(eyeForward: lookForward)
        link.update { [hands] in
            $0.head = SIMD3(headInView.x, headInView.y, headInView.z); $0.up = up
            $0.facing = SIMD2(levelBack.x, levelBack.z)
            $0.geometry = geometry; $0.hands = hands; $0.dioramaForward = dioramaForward; $0.busy = busy
            $0.picks += picks; $0.chest = chestPose
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
        for (slot, drawable) in drawables.enumerated() {
            let trackingAreas = diorama == nil ? props.chestTrackingAreas(chest, drawable: drawable) : []
            for (index, view) in drawable.views.enumerated() {
                let roomFromEye = head * view.transform
                let eye = GameRenderer.RoomEye(
                    viewProjection: drawable.computeProjection(viewIndex: index) * roomFromEye.inverse,
                    roomFromView: roomFromView,
                    roomFromWindow: placement.roomFromWindow,
                    windowFromRoom: placement.roomFromWindow.inverse,
                    eye: placement.roomFromWindow.inverse * roomFromEye.columns.3,
                    window: SIMD4(placement.halfSize.x, placement.halfSize.y, placement.skyDistance, placement.edgeFade),
                    up: SIMD4(up, 0))
                guard let encoder = makeEncoder(commands, drawable: drawable, slot: slot, view: view) else { continue }
                // Open: the game through the window (or the title screen's face), fading out at its edges to the
                // room. Closed: the cartridge.
                // Then the room's surfaces into depth and Mario, if he's out in the room, hidden by them
                if let diorama, let roomFromWorld {
                    if let gameFrame {
                        game.encodeDiorama(gameFrame, into: encoder, eye: eye, roomFromWorld: roomFromWorld,
                                           table: diorama.table, xScale: xScale)
                    }
                } else if cartridge.isOpen {
                    if let gameFrame, let title = gameFrame.title {
                        props.encodeTitle(title, window: placement, time: time - (startTime ?? 0), into: encoder, eye: eye)
                    } else if let gameFrame {
                        game.encodeRoom(gameFrame, into: encoder, eye: eye, actors: false,
                                        roomFromClip: roomFromClip, actorFromClip: actorFromClip) { [props] in
                            if let near = nearPicture {
                                props.encodeWindowPicture(placement, picture: near.color, depth: near.depth,
                                                          nearer: near.nearer, into: encoder, eye: eye)
                            }
                        }
                    }
                } else {
                    props.encodeCartridge(cartridge.pose, into: encoder, eye: eye)
                }
                if diorama == nil, let gameFrame, gameFrame.actorsOutside {
                    if let mesh = room.buffer { game.encodeRoomMesh(mesh, count: room.count, into: encoder, eye: eye) }
                    game.encodeRoom(gameFrame, into: encoder, eye: eye, actors: true,
                                    roomFromClip: roomFromClip, actorFromClip: actorFromClip)
                }
                // The handle, and where the window will go down, last: they're blended (into depth only where they
                // show), so whatever came after them (Mario out in the room) would paint over
                // their soft edges
                props.encodeChest(chest, into: encoder, eye: eye)
                if diorama == nil, cartridge.isOpen {
                    props.encodeHandle(placement, held: !cartridge.holding.isEmpty, into: encoder, eye: eye)
                }
                if diorama == nil, cartridge.isOpen, let circle {
                    let glow = Float(0.75 + 0.25 * sin(time * 6))
                    props.encodeCircle(at: circle, radius: Diorama.radius, glow: glow, into: encoder, eye: eye)
                }
                if graphics?.gloves == true { props.encodeGloves(hands, into: encoder, eye: eye) }
                encoder.endEncoding()
                if !trackingAreas.isEmpty,
                   let tracking = makeTrackingEncoder(commands, drawable: drawable, view: view) {
                    props.encodeTrackingAreas(trackingAreas, format: layer.configuration.trackingAreasFormat,
                                              into: tracking, eye: eye)
                    tracking.endEncoding()
                }
            }
            drawable.encodePresent(commandBuffer: commands)
        }
        if !drewFirstFrame, let gameFrame {
            drewFirstFrame = true
            Self.log.info("First frame in the room: \(gameFrame.draws.count) draws")
        }
        if PerfLog.enabled {
            commands.addCompletedHandler { [perf] done in perf.addAnyThread("gpu", done.gpuEndTime - done.gpuStartTime) }
        }
        commands.commit()
        perf.add("cpu", PerfLog.now - cpuStart)
        perf.step(extra: "\(gameFrame?.draws.count ?? 0) game draws")
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
            h.joints = HandState.debugJoints(pinch: p, eye: eye)
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

    /// With -chest (and -demo, into Castle Grounds): 2 s after Mario can play, a fingertip touches the treasure chest open;
    /// a hand pinches the Goomba out and puts it down on the stand-in room's counter; then looks and pinches take a
    /// coin box and two more Marios into the level near Mario
    private var chestSince: TimeInterval?
    private var chestHandFrom: SIMD3<Float>?
    private var chestGazed = Set<Int>()

    private func scriptedChestInput(_ time: TimeInterval, stage: Int32, eye: SIMD3<Float>) -> ([HandState], [GazePinch]) {
        func hand(_ p: SIMD3<Float>, pinching: Bool) -> HandState {
            var h = HandState(tracked: true)
            h.pinch = p; h.reach = p; h.pinching = pinching
            h.palm = p + SIMD3(0, -0.05, 0.08)
            h.joints = HandState.debugJoints(pinch: p, eye: eye)
            return h
        }
        if chestSince == nil {
            guard stage == 3, chest.available(.goomba) else { return ([], []) }  // (past the intro: Mario's to play)
            chestSince = time
        }
        let s = time - chestSince!
        let up = SIMD3<Float>(chest.pose.columns.1.x, chest.pose.columns.1.y, chest.pose.columns.1.z)
        let front = SIMD3<Float>(chest.pose.columns.2.x, chest.pose.columns.2.y, chest.pose.columns.2.z)
        let middle = SIMD3<Float>(chest.pose.columns.3.x, chest.pose.columns.3.y, chest.pose.columns.3.z)
        if s > 2 && s < 3 {  // a fingertip from in front, into the chest and out again
            let k = Float(1 - abs(s - 2.5) * 2)
            return ([HandState(), hand(middle + up * 0.04 + front * (0.15 - 0.13 * k), pinching: false)], [])
        }
        if s > 4.5 && s < 8, let tile = chest.tileCenter(.goomba), let to = link.current.debugRelease {
            if chestHandFrom == nil { chestHandFrom = tile }
            let from = chestHandFrom!, over = SIMD3(to.x, max(from.y, to.y) + 0.08, to.z)
            let k = Float(min(max((s - 5) / 2.2, 0), 1))
            // (up and over, then down onto it: not through the chest)
            let p = k < 0.7 ? from + (over - from) * (k / 0.7) : over + (to + SIMD3(0, 0.06, 0) - over) * ((k - 0.7) / 0.3)
            return ([HandState(), hand(p, pinching: s > 4.8 && s < 7.4)], [])
        }
        for (at, kind) in [(9.0, SpawnKind.coinBox), (11.0, .mario), (12.5, .mario)] where s > at && s < at + 0.3 {
            guard let tile = chest.tileCenter(kind) else { break }
            let p = eye + SIMD3(0.15, -0.45, -0.25)
            let id = 3_000_000 + Int(at * 10)
            let gaze = GazePinch(id: id, began: chestGazed.insert(id).inserted, origin: eye,
                                 direction: simd_normalize(tile - eye), hand: 1, position: p)
            return ([HandState(), hand(p, pinching: true)], [gaze])
        }
        return ([], [])
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
            h.joints = HandState.debugJoints(pinch: p, eye: eye)
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
        latestRoom.withLockUnchecked { $0 = mesh }
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

    /// The game's flat picture of its level (no sky or HUD) and its depth, into textures 1920 wide
    private func renderWindowPicture(_ frame: GameFrame, commands: MTLCommandBuffer)
        -> (color: MTLTexture, depth: MTLTexture)? {
        let width = 1920, height = max(1, Int(Float(width) * Float(frame.size.y) / Float(max(frame.size.x, 1))))
        if windowPicture.map({ $0.color.width != width || $0.color.height != height }) ?? true {
            func make(_ format: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                 mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            guard let color = make(GameRenderer.Target.flat.colorFormat),
                  let depth = make(GameRenderer.Target.flat.depthFormat) else { return nil }
            windowPicture = (color, depth)
            windowPictureOf = nil
        }
        guard let picture = windowPicture else { return nil }
        let of = (number: frame.number, vertices: frame.vertices.map(ObjectIdentifier.init), anisotropy: game.anisotropy)
        if let last = windowPictureOf, last == of { return picture }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = picture.color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = picture.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        flat.anisotropy = game.anisotropy
        flat.encode(frame, into: encoder, target: SIMD2(Double(width), Double(height)), worldOnly: true)
        encoder.endEncoding()
        windowPictureOf = of
        return picture
    }

    /// The options menu's graphics, as the game last gave them: the render quality, MSAA, anisotropy
    private func applyOptions() {
        let wanted = link.current.graphics
        guard wanted != graphics else { return }
        if wanted.resolution != graphics?.resolution, let quality = RoomLayerConfiguration.quality(wanted.resolution) {
            let most = layer.configuration.maxRenderQuality.rawValue
            layer.renderQuality = LayerRenderer.RenderQuality(rawValue: min(quality, most))
        }
        let samples = device.supportsTextureSampleCount(wanted.sampleCount) ? wanted.sampleCount : 1
        if samples != game.sampleCount { multisample.removeAll() }
        game.sampleCount = samples
        props.sampleCount = samples
        game.anisotropy = wanted.mipmaps ? wanted.anisotropy : 1
        graphics = wanted
    }

    private var device: MTLDevice { game.device }

    private func makeEncoder(_ commands: MTLCommandBuffer, drawable: LayerRenderer.Drawable, slot: Int,
                             view: LayerRenderer.Drawable.View) -> MTLRenderCommandEncoder? {
        let map = view.textureMap
        let color = drawable.colorTextures[map.textureIndex], depth = drawable.depthTextures[map.textureIndex]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0  // (reversed depth: far is 0)
        if game.sampleCount > 1, let targets = multisampleTargets(view: slot * 64 + map.textureIndex * 8 + map.sliceIndex,
                                                                     like: color, depth: depth) {
            // MSAA: drawn into the samples, resolved into the drawable (depth too, the nearest: the compositor
            // reprojects with it)
            pass.colorAttachments[0].texture = targets.color
            pass.colorAttachments[0].resolveTexture = color
            pass.colorAttachments[0].resolveSlice = map.sliceIndex
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.depthAttachment.texture = targets.depth
            pass.depthAttachment.resolveTexture = depth
            pass.depthAttachment.resolveSlice = map.sliceIndex
            pass.depthAttachment.depthResolveFilter = .max  // (reversed depth: nearer is more)
            pass.depthAttachment.storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].slice = map.sliceIndex
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.slice = map.sliceIndex
            pass.depthAttachment.storeAction = .store
        }
        if layer.configuration.isFoveationEnabled {  // (foveation: the drawable's rate map for this view)
            let maps = drawable.rasterizationRateMaps
            if !maps.isEmpty { pass.rasterizationRateMap = maps[min(map.textureIndex, maps.count - 1)] }
        }
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        encoder?.setViewport(map.viewport)
        return encoder
    }

    /// A view's tracking areas (cleared: none), for what's drawn into it to light up when you look at it
    private func makeTrackingEncoder(_ commands: MTLCommandBuffer, drawable: LayerRenderer.Drawable,
                                     view: LayerRenderer.Drawable.View) -> MTLRenderCommandEncoder? {
        let map = view.textureMap, textures = drawable.trackingAreasTextures
        guard map.textureIndex < textures.count else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = textures[map.textureIndex]
        pass.colorAttachments[0].slice = map.sliceIndex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if layer.configuration.isFoveationEnabled {  // (as the view's colour is: the same pixels)
            let maps = drawable.rasterizationRateMaps
            if !maps.isEmpty { pass.rasterizationRateMap = maps[min(map.textureIndex, maps.count - 1)] }
        }
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        encoder?.setViewport(map.viewport)
        return encoder
    }

    /// A view's MSAA colour and depth, the drawable's size (memoryless: they never leave the GPU's tiles)
    private func multisampleTargets(view: Int, like color: MTLTexture, depth: MTLTexture)
        -> (color: MTLTexture, depth: MTLTexture)? {
        if let t = multisample[view], t.color.width == color.width, t.color.height == color.height { return t }
        func make(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DMultisample
            d.pixelFormat = format
            d.width = color.width
            d.height = color.height
            d.sampleCount = game.sampleCount
            d.usage = .renderTarget
            d.storageMode = .memoryless
            if let t = device.makeTexture(descriptor: d) { return t }
            d.storageMode = .private  // (where memoryless isn't there)
            return device.makeTexture(descriptor: d)
        }
        guard let c = make(color.pixelFormat), let d = make(depth.pixelFormat) else { return nil }
        multisample[view] = (c, d)
        return (c, d)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (s, attoseconds) = duration.components
        return Double(s) + Double(attoseconds) * 1e-18
    }
}

// ---------------------------------------------------------------- Mario 128 in your room

extension ImmersiveRenderer {
    /// A frame of Mario 128 in your room (Mario128Stage): no cartridge nor window. Mario in front of you, in your
    /// hand, or the stage where he was put down, hidden where the room's surfaces are in front; its count over the
    /// picture
    private func renderMario128(_ drawables: [LayerRenderer.Drawable], commands: MTLCommandBuffer, head: simd_float4x4,
                                realHead: Bool, time: TimeInterval, now: CFTimeInterval) {
        let eyePosition = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let lookForward = -SIMD3(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        if mario128 == nil, realHead || !WorldTrackingProvider.isSupported || now - (started ?? now) > 2 {
            mario128 = Mario128Stage(eye: eyePosition, forward: lookForward)
            if startTime == nil { startTime = time }
            Self.log.info("Mario 128 in your room: Mario in front of you")
            #if DEBUG
            if !RoomScanner.isSupported {  // (the simulator: a floor and a table to put him down on)
                let (room, above, planes) = RoomMesh.standIn(window: RoomPlacement(facing: head),
                                                              floor: head.columns.3.y - 1.5)
                useRoom(room)
                standInPlanes = planes
                link.update { $0.debugRelease = above }
            }
            #endif
        }
        var hands = handTracker.update(at: time)
        while hands.count < 2 { hands.append(HandState()) }
        for (side, hand, _) in controllerTracker.hands(at: time) { hands[side] = hand }
        _ = gazePinches.take()  // (looks and pinches from afar aren't used here)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-mario128"), let stage = mario128 {
            hands = scriptedMario128Hands(time, stage: stage, eye: eyePosition)
        }
        #endif
        lastTime = time
        let planes = planeFinder.current + standInPlanes
        let gameFrame = frames.latest()
        let state = link.current
        let ready = state.stageRoom != 0  // (the game's on the stage, holding him)
        if let stage = mario128, ready {
            let room = latestRoom.withLockUnchecked { $0 }
            let put = stage.update(hands: hands, eye: eyePosition) { p in
                room?.ground(under: p, depth: Mario128Stage.dropMost) ?? Self.circle(under: p, planes: planes).map(\.y)
            }
            if put, let placed = stage.placed {
                let triangles = room?.stageTriangles(worldFromRoom: stage.roomFromWorld().inverse) ?? []
                Self.log.info("Mario 128 put down \(placed.height) m over a surface, on \(triangles.count / 9) of the room's triangles")
                link.update { $0.stagePlace = (triangles, placed.height / Mario128Stage.scale) }
            }
            scanner.focus = stage.at
        }

        let roomFromWorld = mario128?.roomFromWorld() ?? matrix_identity_float4x4
        let camera = gameFrame?.camera ?? matrix_identity_float4x4
        let roomFromView = roomFromWorld * camera.inverse
        let up = simd_normalize(SIMD3(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z))
        let headInView = roomFromView.inverse * head.columns.3
        let back = head.columns.2, headUp = head.columns.1
        let levelBack = back - headUp * (back.y >= 0 ? 1 : -1)
        let geometry = RoomGeometry(roomFromView: roomFromView, windowFromRoom: matrix_identity_float4x4,
                                    halfSize: SIMD2(0.3, 0.2), open: true, diorama: true,
                                    startLabel: (.zero, .zero), worldFromRoom: roomFromWorld.inverse)
        let forward = mario128?.forwardInWorld(eyeForward: lookForward)
        link.update {
            $0.head = SIMD3(headInView.x, headInView.y, headInView.z); $0.up = up
            $0.facing = SIMD2(levelBack.x, levelBack.z)
            $0.geometry = geometry; $0.hands = []; $0.dioramaForward = forward; $0.busy = []; $0.chest = nil
        }

        let mesh = roomMesh.withLockUnchecked { $0 }
        let xScale = gameFrame.map { RoomPlacement.xScale($0.size) } ?? 0.75
        // (the count over the picture's middle, 6 cm up: stage_mosaic_lay_at's, ahead of where he was put down)
        let countAt = roomFromWorld * SIMD4<Float>(0, 480, -1080, 1)
        for (slot, drawable) in drawables.enumerated() {
            for (index, view) in drawable.views.enumerated() {
                let roomFromEye = head * view.transform
                let eye = GameRenderer.RoomEye(
                    viewProjection: drawable.computeProjection(viewIndex: index) * roomFromEye.inverse,
                    roomFromView: roomFromView, roomFromWindow: matrix_identity_float4x4,
                    windowFromRoom: matrix_identity_float4x4, eye: roomFromEye.columns.3,
                    window: SIMD4(1, 1, 100, 0.01), up: SIMD4(up, 0))
                guard let encoder = makeEncoder(commands, drawable: drawable, slot: slot, view: view) else { continue }
                // The room's surfaces into depth, then the stage (none of it cut away: what falls off the table is
                // seen falling), then its count
                if let buffer = mesh.buffer { game.encodeRoomMesh(buffer, count: mesh.count, into: encoder, eye: eye) }
                if ready, mario128 != nil, let gameFrame {
                    game.encodeDiorama(gameFrame, into: encoder, eye: eye, roomFromWorld: roomFromWorld, table: -1e6,
                                       xScale: xScale)
                }
                if state.stageRoom == 2, state.stageCount > 0 {
                    props.encodeCount(state.stageCount, at: SIMD3(countAt.x, countAt.y, countAt.z), facing: eyePosition,
                                      into: encoder, eye: eye)
                }
                if graphics?.gloves == true { props.encodeGloves(hands, into: encoder, eye: eye) }
                encoder.endEncoding()
            }
            drawable.encodePresent(commandBuffer: commands)
        }
        commands.commit()
    }

    #if DEBUG
    /// With -mario128 (and -demo, into a course; the flat window's button pressed for you): a hand, as the simulator
    /// has none, takes Mario from in front of you, carries him over the stand-in room's counter and lets go 6 cm
    /// above it
    private func scriptedMario128Hands(_ time: TimeInterval, stage: Mario128Stage, eye: SIMD3<Float>) -> [HandState] {
        guard link.current.stageRoom != 0, let above = link.current.debugRelease else { return [] }
        if mario128Since == nil { mario128Since = time }
        if mario128From == nil { mario128From = stage.at + SIMD3(0, Mario128Stage.middle, 0) }
        let s = time - mario128Since!, from = mario128From!
        func hand(_ p: SIMD3<Float>, pinching: Bool) -> HandState {
            var h = HandState(tracked: true)
            h.pinch = p; h.reach = p; h.pinching = pinching
            h.palm = p + SIMD3(0, -0.05, 0.08)
            h.joints = HandState.debugJoints(pinch: p, eye: eye)
            return h
        }
        let to = above - SIMD3(0, 0.25 - 0.06 - Mario128Stage.middle, 0)  // (debugRelease is 25 cm over the counter)
        if s < 1 { return [HandState(), hand(from + SIMD3(0, 0.05 * Float(1 - s), 0), pinching: false)] }
        if s < 4 {
            let k = Float(min(max((s - 1.3) / 2, 0), 1))
            return [HandState(), hand(from + (to - from) * k, pinching: s > 1.1 && s < 3.6)]
        }
        return []
    }
    #endif
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
        /// The Sense controllers (by side, 0 left, 1 right) whose grip holds the cartridge, the window or the base:
        /// their stick and trigger work it, not the game
        var busy: Set<Int> = []
        /// The room closed out of a diorama (the Digital Crown): it opens again at once, the window open this wide
        /// (metres), rather than going back to the flat window
        var reopenWidth: Float?
        /// (from the game) the options menu's graphics
        var graphics = GameOptions.savedGraphics
        /// What was taken out of the treasure chest since the game last looked (it takes them), and (from the game)
        /// which kinds it can spawn now, bits by SpawnKind
        var picks: [ChestPick] = []
        var spawnable: UInt32 = 0
        /// The chest for the game to draw in the room (the game's own), when it's shown
        var chest: ChestPose?
        /// Mario 128 in your room (the flat window's button, as the room opens): the game begins it, and ends it as
        /// the room closes
        var mario128 = false
        /// Mario put down there: the room's triangles about it in the game's world, and his height (units), for the
        /// game to take (sm64unity_stage_room_place)
        var stagePlace: (triangles: [Int16], marioY: Float)?
        /// (from the game) Mario 128 in your room: 0 not yet, 1 held, 2 put down; and how many Marios
        var stageRoom: Int32 = 0
        var stageCount: Int32 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Called (on the room's thread) when the room closes
    var onClose: (@Sendable () -> Void)?

    func update(_ change: @Sendable (inout State) -> Void) { state.withLock(change) }
    var current: State { state.withLock { $0 } }
}
