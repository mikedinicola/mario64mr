import ARKit
import Foundation
import os
import QuartzCore
import simd

/// Your room's surfaces, as triangles in the room (metres; ARKit's origin, on the floor where the space opened).
///
/// The game has a room space of its own for Mario once he's out of the window (sm64unity_room_mesh, carry modes 2
/// and 3): the room in game units, at the window's scale (RoomPlacement.unitsPerMetre), from ARKit's origin. The
/// game keeps it within ±8000 units (13 m at 600 a metre) and 30000 triangles.
struct RoomMesh {
    var triangles: [SIMD3<Float>] = []  // three corners each, counterclockwise from their front

    static let maxTriangles = 30000

    /// In the game's room space: nine s16 a triangle; those beyond ±8000 units, or too thin to stand on, left out
    func gameTriangles() -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(min(triangles.count, Self.maxTriangles * 3) * 3)
        var i = 0
        while i + 2 < triangles.count, out.count < Self.maxTriangles * 9 {
            let corners = [triangles[i], triangles[i + 1], triangles[i + 2]].map {
                ($0 * RoomPlacement.unitsPerMetre).rounded(.toNearestOrEven)
            }
            i += 3
            guard corners.allSatisfy({ simd_reduce_max(simd_abs($0)) <= 8000 }),
                  simd_length(simd_cross(corners[1] - corners[0], corners[2] - corners[0])) > 1 else { continue }
            for c in corners { out += [Int16(c.x), Int16(c.y), Int16(c.z)] }
        }
        return out
    }

    /// A stand-in room for the simulator, which has no scene reconstruction: a floor, and a box like a counter,
    /// 1.2 m high, in front of the window's lower right (where the simulator's view sees it). Returns it and a
    /// point just above the box, and the floor and the box's top as planes for the cartridge. (The simulator's origin
    /// is at the head, not on the floor: `floor` is its height.)
    static func standIn(window: RoomPlacement, floor floorHeight: Float) -> (RoomMesh, SIMD3<Float>, [RoomPlane]) {
        var mesh = RoomMesh()
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            mesh.triangles += [a, b, c, a, c, d]
        }
        let w = window.roomFromWindow
        let toward = SIMD3(w.columns.2.x, 0, w.columns.2.z), right = SIMD3(w.columns.0.x, 0, w.columns.0.z)
        let under = SIMD3(w.columns.3.x, floorHeight, w.columns.3.z)
        let floor: Float = 4
        quad(under - right * floor - toward * floor, under - right * floor + toward * floor,
             under + right * floor + toward * floor, under + right * floor - toward * floor)
        let center = under + toward * 0.5 + right * 0.3, height: Float = 1.2
        let x = right * 0.25, z = toward * 0.2, y = SIMD3<Float>(0, height, 0)
        quad(center - x - z + y, center - x + z + y, center + x + z + y, center + x - z + y)  // top
        quad(center - x + z, center + x + z, center + x + z + y, center - x + z + y)          // sides
        quad(center + x - z, center - x - z, center - x - z + y, center + x - z + y)
        quad(center - x - z, center - x + z, center - x + z + y, center - x - z + y)
        quad(center + x + z, center + x - z, center + x - z + y, center + x + z + y)
        func plane(_ corners: [SIMD3<Float>]) -> RoomPlane {
            RoomPlane(height: corners[0].y, triangles: [0, 1, 2, 0, 2, 3].map { SIMD2(corners[$0].x, corners[$0].z) })
        }
        let planes = [
            plane([under - right * floor - toward * floor, under - right * floor + toward * floor,
                   under + right * floor + toward * floor, under + right * floor - toward * floor]),
            plane([center - x - z + y, center - x + z + y, center + x + z + y, center + x - z + y]),
        ]
        return (mesh, center + y + SIMD3(0, 0.25, 0), planes)
    }
}

/// Reads the room from scene reconstruction while the immersive space is open, and hands it on whenever it changes
/// (at most once a second)
final class RoomScanner: @unchecked Sendable {
    let provider = SceneReconstructionProvider()
    private var anchors: [UUID: (center: SIMD3<Float>, triangles: [SIMD3<Float>])] = [:]
    /// What the scanner had and dropped (a mesh anchor removed: visionOS keeps only so much of the room), and what a
    /// saved room brought back (RoomStore): where the live scan has nothing of its own (RoomMesh.uncovered), after
    /// it. Each triangle with the launches since it was last seen
    private var kept: [SIMD3<Float>] = []
    private var keptAges: [UInt8] = []
    static let mostKept = 40000  // triangles
    private let restored = OSAllocatedUnfairLock<[([SIMD3<Float>], [UInt8])]>(initialState: [])
    private let published = OSAllocatedUnfairLock<([SIMD3<Float>], [UInt8])>(initialState: ([], []))
    private var lastPublished = Date.distantPast
    private let focusLock = OSAllocatedUnfairLock<SIMD3<Float>>(initialState: .zero)
    /// Where Mario plays (the window), metres: the game takes only so many triangles (RoomMesh.maxTriangles), and
    /// the pieces of the room nearest here go first, so the ones he's put on are never the ones left out
    var focus: SIMD3<Float> {
        get { focusLock.withLock { $0 } }
        set { focusLock.withLock { $0 = newValue } }
    }

    static var isSupported: Bool { SceneReconstructionProvider.isSupported }

    /// A saved room back (RoomStore), in the room: kept from the next time the scan changes
    func restore(_ triangles: [SIMD3<Float>], ages: [UInt8]) { restored.withLock { $0.append((triangles, ages)) } }

    /// The room as last handed on (the live scan's, then what's kept), with each triangle's age: for saving
    var current: (triangles: [SIMD3<Float>], ages: [UInt8]) { published.withLock { (triangles: $0.0, ages: $0.1) } }

    func run(publish: @escaping (RoomMesh) -> Void) async {
        for await update in provider.anchorUpdates {
            switch update.event {
            case .added, .updated:
                let t = update.anchor.originFromAnchorTransform.columns.3
                anchors[update.anchor.id] = (SIMD3(t.x, t.y, t.z), Self.triangles(of: update.anchor))
            case .removed:
                if let gone = anchors.removeValue(forKey: update.anchor.id) {
                    kept += gone.triangles
                    keptAges += [UInt8](repeating: 0, count: gone.triangles.count / 3)
                }
            @unknown default: break
            }
            if Date.now.timeIntervalSince(lastPublished) > 1 {
                lastPublished = .now
                for (triangles, ages) in restored.withLock({ r in defer { r = [] }; return r }) {
                    kept = triangles + kept
                    keptAges = ages + keptAges
                }
                let focus = self.focus
                let near = anchors.values.sorted { simd_distance($0.center, focus) < simd_distance($1.center, focus) }
                let live = near.flatMap { $0.triangles }
                (kept, keptAges) = RoomMesh.uncovered(kept, ages: keptAges, by: live)
                if keptAges.count > Self.mostKept {  // (the newest kept)
                    kept.removeFirst((keptAges.count - Self.mostKept) * 3)
                    keptAges.removeFirst(keptAges.count - Self.mostKept)
                }
                let ages = [UInt8](repeating: 0, count: live.count / 3) + keptAges
                published.withLock { $0 = (live + kept, ages) }
                publish(RoomMesh(triangles: live + kept))
            }
        }
    }

    /// The anchor's faces in the room, each turned to face the way the surface does (its vertices' normals): the
    /// game takes a triangle's front from its corners' order (counterclockwise: a floor faces up, a ceiling down)
    private static func triangles(of anchor: MeshAnchor) -> [SIMD3<Float>] {
        let geometry = anchor.geometry, vertices = geometry.vertices, normals = geometry.normals, faces = geometry.faces
        guard vertices.format == .float3, faces.primitive == .triangle, faces.bytesPerIndex == 4 else { return [] }
        let base = vertices.buffer.contents().advanced(by: vertices.offset)
        let normalBase = normals.format == .float3 && normals.count == vertices.count
            ? normals.buffer.contents().advanced(by: normals.offset) : nil
        let transform = anchor.originFromAnchorTransform
        func corner(_ index: UInt32) -> SIMD3<Float> {
            let p = base.advanced(by: Int(index) * vertices.stride).assumingMemoryBound(to: Float.self)
            let world = transform * SIMD4(p[0], p[1], p[2], 1)
            return SIMD3(world.x, world.y, world.z)
        }
        func normal(_ index: UInt32) -> SIMD3<Float> {
            guard let normalBase else { return .zero }
            let n = normalBase.advanced(by: Int(index) * normals.stride).assumingMemoryBound(to: Float.self)
            let world = transform * SIMD4(n[0], n[1], n[2], 0)
            return SIMD3(world.x, world.y, world.z)
        }
        let indices = faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(faces.count * 3)
        for f in 0..<faces.count {
            let i = (indices[f * 3], indices[f * 3 + 1], indices[f * 3 + 2])
            let a = corner(i.0), b = corner(i.1), c = corner(i.2)
            let facing = normal(i.0) + normal(i.1) + normal(i.2)
            out += simd_dot(simd_cross(b - a, c - a), facing) < 0 ? [a, c, b] : [a, b, c]
        }
        return out
    }
}

/// Your room kept between launches: visionOS scans it afresh each time, from nothing. Saved every 20 seconds against
/// a world anchor (which visionOS keeps, and finds again the next time you're in the same room), in Application
/// Support/Rooms, a file a room; when that anchor's found again, its room comes back into the scanner (`restore`),
/// filling in what the scan hasn't got to yet. What the live scan sees again is its own; what it doesn't, kept
/// for forgetAfter launches, then forgotten (moved, or gone)
actor RoomStore {
    static let forgetAfter: UInt8 = 3
    static let mostRooms = 8
    /// How long a saved room has to be found before a new one is begun, seconds
    static let findFor: TimeInterval = 45
    private let directory = URL.applicationSupportDirectory.appending(path: "Rooms", directoryHint: .isDirectory)
    private var transforms: [UUID: simd_float4x4] = [:]  // the anchors found (tracked), where they are
    private var loaded: Set<UUID> = []
    private var home: UUID?  // the anchor this launch's room is saved against
    private var made: UUID?  // an anchor begun this launch (no saved room found in time)
    private static let log = Logger(subsystem: "local.mario64mr", category: "Room")

    private func file(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).room") }

    func run(world: WorldTrackingProvider, scanner: RoomScanner) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = Date.now
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await update in world.anchorUpdates { await self.found(update, world: world, scanner: scanner) } }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    await self.save(world: world, scanner: scanner, started: started)
                }
            }
        }
    }

    private func found(_ update: AnchorUpdate<WorldAnchor>, world: WorldTrackingProvider, scanner: RoomScanner) async {
        let anchor = update.anchor
        guard update.event != .removed, anchor.isTracked else { transforms[anchor.id] = nil; return }
        transforms[anchor.id] = anchor.originFromAnchorTransform
        guard !loaded.contains(anchor.id), let data = try? Data(contentsOf: file(anchor.id)) else { return }
        loaded.insert(anchor.id)
        if let (triangles, ages) = RoomMesh.savedRoom(data, originFromAnchor: anchor.originFromAnchorTransform,
                                                      forgetAfter: Self.forgetAfter) {
            scanner.restore(triangles, ages: ages)
            Self.log.info("The room from before: \(ages.count) triangles back")
        }
        // (found after one was begun: this one's the room, the one begun gone)
        if let made, made != anchor.id {
            try? FileManager.default.removeItem(at: file(made))
            try? await world.removeAnchor(forID: made)
            if home == made { home = nil }
            self.made = nil
        }
        if home == nil { home = anchor.id }
    }

    private func save(world: WorldTrackingProvider, scanner: RoomScanner, started: Date) async {
        let room = scanner.current
        guard room.ages.count >= 500 else { return }
        if home == nil {
            guard Date.now.timeIntervalSince(started) > Self.findFor,
                  let head = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())?.originFromAnchorTransform
            else { return }
            var at = matrix_identity_float4x4
            at.columns.3 = head.columns.3
            let anchor = WorldAnchor(originFromAnchorTransform: at)
            do { try await world.addAnchor(anchor) } catch { return Self.log.error("No anchor for the room: \(error)") }
            transforms[anchor.id] = at
            home = anchor.id; made = anchor.id; loaded.insert(anchor.id)
            await forgetOldest(world: world)
        }
        guard let home, let originFromAnchor = transforms[home] else { return }  // (not tracked just now)
        let data = RoomMesh.savedRoom(room.triangles, ages: room.ages, anchorFromOrigin: originFromAnchor.inverse)
        do { try data.write(to: file(home), options: .atomic) } catch { Self.log.error("The room didn't save: \(error)") }
    }

    /// At most mostRooms saved: the one longest unsaved forgotten, and its anchor
    private func forgetOldest(world: WorldTrackingProvider) async {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > Self.mostRooms else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - Self.mostRooms) {
            try? FileManager.default.removeItem(at: url)
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), id != home {
                try? await world.removeAnchor(forID: id)
            }
        }
    }
}

/// The room's horizontal planes (tables, desks, the floor) from plane detection, for the cartridge to land on
final class PlaneFinder: @unchecked Sendable {
    let provider = PlaneDetectionProvider(alignments: [.horizontal])
    private let planes = OSAllocatedUnfairLock<[UUID: RoomPlane]>(initialState: [:])

    static var isSupported: Bool { PlaneDetectionProvider.isSupported }

    var current: [RoomPlane] { planes.withLock { Array($0.values) } }

    func run() async {
        for await update in provider.anchorUpdates {
            let anchor = update.anchor
            switch update.event {
            case .added, .updated:
                let plane = Self.plane(of: anchor)
                planes.withLock { $0[anchor.id] = plane }
            case .removed: planes.withLock { $0[anchor.id] = nil }
            @unknown default: break
            }
        }
    }

    /// Its outline's triangles (the plane's mesh) in the room, flattened onto the floor's plane
    private static func plane(of anchor: PlaneAnchor) -> RoomPlane? {
        let vertices = anchor.geometry.meshVertices, faces = anchor.geometry.meshFaces
        guard vertices.format == .float3, faces.primitive == .triangle, faces.bytesPerIndex == 4,
              vertices.count > 0 else { return nil }
        let base = vertices.buffer.contents().advanced(by: vertices.offset)
        let transform = anchor.originFromAnchorTransform
        var corners: [SIMD3<Float>] = []
        for v in 0..<vertices.count {
            let p = base.advanced(by: v * vertices.stride).assumingMemoryBound(to: Float.self)
            let world = transform * SIMD4(p[0], p[1], p[2], 1)
            corners.append(SIMD3(world.x, world.y, world.z))
        }
        let indices = faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
        var triangles: [SIMD2<Float>] = []
        for i in 0..<(faces.count * 3) where Int(indices[i]) < corners.count {
            let c = corners[Int(indices[i])]
            triangles.append(SIMD2(c.x, c.z))
        }
        let height = corners.map(\.y).reduce(0, +) / Float(corners.count)
        return RoomPlane(height: height, triangles: triangles)
    }
}

// MARK: - The scan's gaps, filled from the planes

extension RoomMesh {
    /// Squares a side, metres, the planes are filled in by
    static let fillCell: Float = 0.05
    /// How near a plane's height the scan's own surface must be, metres, for the plane to be taken as scanned there
    static let fillNear: Float = 0.04
    /// How near a plane's height a scanned corner over it is put onto it, metres
    static let snapNear: Float = 0.025

    /// The scan with the detected planes (tables, the floor: PlaneFinder) laid in where it has none of its own: what
    /// plane detection found that scene reconstruction didn't (a dark or glossy tabletop, a rug in dim light). Each
    /// plane in fillCell squares, those whose middle is in its outline and with no surface of the scan's facing up
    /// within fillNear of its height, a row's run of them one strip (two triangles, facing up). Ahead of the scan's,
    /// so that the game's maxTriangles never leaves them out. The second, how many triangles were laid in
    ///
    /// First the scan's corners over a plane and within snapNear of its height put onto it: the lumps of a rug, a
    /// tabletop's few millimetres of noise, flat, not little steps and slopes in the game that stop a Mario 2 cm tall
    func filled(with planes: [RoomPlane]) -> (RoomMesh, Int) {
        guard !planes.isEmpty else { return (self, 0) }
        var triangles = self.triangles
        let bounds = planes.map { plane in
            (plane.triangles.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) },
             plane.triangles.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) })
        }
        for v in triangles.indices {
            let p = triangles[v], q = SIMD2(p.x, p.z)
            for (plane, (lo, hi)) in zip(planes, bounds)
            where abs(p.y - plane.height) < Self.snapNear && all(q .>= lo) && all(q .<= hi) && plane.contains(q) {
                triangles[v].y = plane.height
                break
            }
        }
        let cell = Self.fillCell
        func key(_ x: Float, _ z: Float) -> SIMD2<Int32> { SIMD2(Int32((x / cell).rounded(.down)), Int32((z / cell).rounded(.down))) }
        // The scan's up-facing surfaces (all the game would stand on: unity_upright_wall's), by the cells they cover
        var scanned: [SIMD2<Int32>: [SIMD2<Float>]] = [:]  // (each: lowest and highest)
        var i = 0
        while i + 2 < triangles.count {
            let a = triangles[i], b = triangles[i + 1], c = triangles[i + 2]
            i += 3
            let n = simd_cross(b - a, c - a)
            guard simd_length(n) > 1e-9, simd_normalize(n).y >= 0.5 else { continue }
            let lo = simd_min(a, simd_min(b, c)), hi = simd_max(a, simd_max(b, c))
            let k0 = key(lo.x, lo.z), k1 = key(hi.x, hi.z)
            let cells = Int(k1.x - k0.x + 1) * Int(k1.y - k0.y + 1)
            guard cells <= 100 * 100 else { continue }  // (5 m across: no scan's)
            for x in k0.x...k1.x { for z in k0.y...k1.y { scanned[SIMD2(x, z), default: []].append(SIMD2(lo.y, hi.y)) } }
        }
        func isScanned(_ k: SIMD2<Int32>, _ y: Float) -> Bool {
            scanned[k]?.contains { y >= $0.x - Self.fillNear && y <= $0.y + Self.fillNear } ?? false
        }
        var laid: [SIMD3<Float>] = []
        for plane in planes where !plane.triangles.isEmpty {
            let lo = plane.triangles.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = plane.triangles.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            let k0 = key(lo.x, lo.y), k1 = key(hi.x, hi.y)
            let cells = Int(k1.x - k0.x + 1) * Int(k1.y - k0.y + 1)
            guard cells <= 200 * 200 else { continue }  // (10 m across at most)
            let y = plane.height
            for z in k0.y...k1.y {
                var run: Int32?  // (where a run of gaps along x began)
                for x in k0.x...(k1.x + 1) {
                    let k = SIMD2(x, z)
                    let middle = (SIMD2<Float>(Float(x), Float(z)) + 0.5) * cell
                    let gap = x <= k1.x && plane.contains(middle) && !isScanned(k, y)
                    if gap, run == nil { run = x }
                    if !gap, let from = run {
                        let x0 = Float(from) * cell, x1 = Float(x) * cell, z0 = Float(z) * cell, z1 = z0 + cell
                        laid += [SIMD3(x0, y, z0), SIMD3(x0, y, z1), SIMD3(x1, y, z1),
                                 SIMD3(x0, y, z0), SIMD3(x1, y, z1), SIMD3(x1, y, z0)]
                        run = nil
                    }
                }
            }
        }
        return (RoomMesh(triangles: laid + triangles), laid.count / 3)
    }

    // MARK: Kept: what the scanner dropped, and the room saved from before (RoomScanner, RoomStore)

    /// Cells a side, metres, for telling where the live scan has a surface of its own
    static let coverCell: Float = 0.08

    /// Of `kept` (and their `ages`), those the live scan has nothing of its own near (no triangle's middle in the same
    /// coverCell or one beside it): where it has, its own is newer
    static func uncovered(_ kept: [SIMD3<Float>], ages: [UInt8], by live: [SIMD3<Float>]) -> ([SIMD3<Float>], [UInt8]) {
        guard !kept.isEmpty, !live.isEmpty else { return (kept, ages) }
        func cell(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            let c = (p / coverCell).rounded(.down)
            return SIMD3(Int32(c.x), Int32(c.y), Int32(c.z))
        }
        var seen = Set<SIMD3<Int32>>()
        var i = 0
        while i + 2 < live.count { seen.insert(cell((live[i] + live[i + 1] + live[i + 2]) / 3)); i += 3 }
        var out: [SIMD3<Float>] = [], outAges: [UInt8] = []
        for t in 0..<min(ages.count, kept.count / 3) {
            let c = cell((kept[t * 3] + kept[t * 3 + 1] + kept[t * 3 + 2]) / 3)
            var covered = false
            for dx in Int32(-1)...1 where !covered {
                for dy in Int32(-1)...1 where !covered {
                    for dz in Int32(-1)...1 where seen.contains(c &+ SIMD3(dx, dy, dz)) { covered = true; break }
                }
            }
            if !covered { out += kept[(t * 3)..<(t * 3 + 3)]; outAges.append(ages[t]) }
        }
        return (out, outAges)
    }

    /// A saved room's file: "M64R", version 1, the triangle count, then nine floats a triangle (in its world anchor's
    /// space, metres) and a byte each, the launches since it was last seen
    static func savedRoom(_ triangles: [SIMD3<Float>], ages: [UInt8], anchorFromOrigin: simd_float4x4) -> Data {
        let count = min(ages.count, triangles.count / 3)
        var data = Data("M64R".utf8)
        var header: [UInt32] = [1, UInt32(count)]
        data.append(Data(bytes: &header, count: 8))
        var floats: [Float] = []
        floats.reserveCapacity(count * 9)
        for p in triangles.prefix(count * 3) {
            let a = anchorFromOrigin * SIMD4(p, 1)
            floats += [a.x, a.y, a.z]
        }
        floats.withUnsafeBytes { data.append(contentsOf: $0) }
        data.append(contentsOf: ages.prefix(count))
        return data
    }

    /// A saved room back, into the room (`originFromAnchor`, where its anchor is now), each a launch older: those
    /// older than `forgetAfter` left out (not seen since: moved, or gone)
    static func savedRoom(_ data: Data, originFromAnchor: simd_float4x4, forgetAfter: UInt8) -> ([SIMD3<Float>], [UInt8])? {
        guard data.count >= 12, data.prefix(4) == Data("M64R".utf8) else { return nil }
        let header = data.subdata(in: 4..<12).withUnsafeBytes { (version: $0.load(as: UInt32.self), count: $0.load(fromByteOffset: 4, as: UInt32.self)) }
        let count = Int(header.count)
        guard header.version == 1, data.count == 12 + count * 37 else { return nil }
        let floats = data.subdata(in: 12..<(12 + count * 36)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let ages = data.subdata(in: (12 + count * 36)..<data.count)
        var triangles: [SIMD3<Float>] = [], out: [UInt8] = []
        for t in 0..<count {
            let age = ages[ages.startIndex + t] &+ 1
            guard age <= forgetAfter else { continue }
            for c in 0..<3 {
                let f = (t * 3 + c) * 3
                let p = originFromAnchor * SIMD4(floats[f], floats[f + 1], floats[f + 2], 1)
                triangles.append(SIMD3(p.x, p.y, p.z))
            }
            out.append(age)
        }
        return (triangles, out)
    }
}
