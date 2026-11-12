import ARKit
import Foundation
import os
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
    /// point just above the box. (The simulator's origin is at the head, not on the floor: `floor` is its height.)
    static func standIn(window: RoomPlacement, floor floorHeight: Float) -> (RoomMesh, SIMD3<Float>) {
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
        return (mesh, center + y + SIMD3(0, 0.25, 0))
    }
}

/// Reads the room from scene reconstruction while the immersive space is open, and hands it on whenever it changes
/// (at most once a second)
final class RoomScanner: @unchecked Sendable {
    let provider = SceneReconstructionProvider()
    private var anchors: [UUID: (center: SIMD3<Float>, triangles: [SIMD3<Float>])] = [:]
    private var lastPublished = Date.distantPast
    private let focusLock = OSAllocatedUnfairLock<SIMD3<Float>>(initialState: .zero)
    /// Where Mario plays (the window), metres: the game takes only so many triangles (RoomMesh.maxTriangles), and
    /// the pieces of the room nearest here go first, so the ones he's put on are never the ones left out
    var focus: SIMD3<Float> {
        get { focusLock.withLock { $0 } }
        set { focusLock.withLock { $0 = newValue } }
    }

    static var isSupported: Bool { SceneReconstructionProvider.isSupported }

    func run(publish: @escaping (RoomMesh) -> Void) async {
        for await update in provider.anchorUpdates {
            switch update.event {
            case .added, .updated:
                let t = update.anchor.originFromAnchorTransform.columns.3
                anchors[update.anchor.id] = (SIMD3(t.x, t.y, t.z), Self.triangles(of: update.anchor))
            case .removed: anchors[update.anchor.id] = nil
            @unknown default: break
            }
            if Date.now.timeIntervalSince(lastPublished) > 1 {
                lastPublished = .now
                let focus = self.focus
                let near = anchors.values.sorted { simd_distance($0.center, focus) < simd_distance($1.center, focus) }
                publish(RoomMesh(triangles: near.flatMap { $0.triangles }))
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
