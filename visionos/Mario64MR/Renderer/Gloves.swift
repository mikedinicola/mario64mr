import Foundation
import Metal
import simd

/// Mario's gloves: the gloves of Apple's "Animating hand models in visionOS" sample (MIT, see
/// Gloves/Gloves-LICENSE.txt), only their shape and bones (Gloves/*.glove, made by tools/convert_gloves.swift),
/// drawn white by glove_fragment, with the three black dots on the back of the hand that the game's menu hand has (`dots`). Their 27 joints are the ARKit hand skeleton's, in its order, and rest as it does: as in the sample, each joint
/// keeps the glove's own length and takes the tracked joint's turn (`parentFromJointTransform`), the whole glove
/// placed at the hand's anchor (its wrist).
final class GloveMesh {
    struct Joint {
        var parent: Int
        var translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>
        var inverseBindPose: simd_float4x4
    }

    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int
    /// The mesh's place in the model: the skeleton's centimetres to metres from the wrist
    let instance: simd_float4x4
    let joints: [Joint]
    /// The dots on the back of the hand, for glove_fragment (GloveDots), in the mesh's own space
    let dots: Dots

    /// GloveDots: where the three dots are on the glove at rest (bound: its rest is its bind pose), so they stay
    /// where they are on it however the hand moves. Each a disc seen from the back of the hand (`up`), on the
    /// surfaces that face that way only, so never through to the palm.
    struct Dots {
        var center: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var across: SIMD4<Float>, along: SIMD4<Float>, up: SIMD4<Float>
        /// x: a dot's radius across the hand, y: along it (the mesh's units)
        var size: SIMD4<Float>
    }

    static let jointCount = 27
    /// GloveVertex: position (3 floats), normal (3 floats), joints (4 bytes), weights (4 bytes)
    static let vertexStride = 32

    init?(device: MTLDevice, url: URL) {
        guard let packed = try? Data(contentsOf: url),
              let data = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              data.count > 16, data.prefix(4) == Data("GLV1".utf8) else { return nil }
        var offset = 4
        func read<T>(_: T.Type) -> T {
            defer { offset += MemoryLayout<T>.size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        func matrix() -> simd_float4x4 {
            let c = (0..<4).map { _ in SIMD4(read(Float.self), read(Float.self), read(Float.self), read(Float.self)) }
            return simd_float4x4(c[0], c[1], c[2], c[3])
        }
        func vector() -> SIMD3<Float> { SIMD3(read(Float.self), read(Float.self), read(Float.self)) }
        let vertexCount = Int(read(UInt32.self)), indexCount = Int(read(UInt32.self))
        let jointCount = Int(read(UInt32.self))
        guard jointCount == Self.jointCount else { return nil }
        instance = matrix()
        let joints = (0..<jointCount).map { _ in
            let parent = Int(read(Int32.self)), t = vector()
            let r = simd_quatf(ix: read(Float.self), iy: read(Float.self), iz: read(Float.self), r: read(Float.self))
            let s = vector()
            return Joint(parent: parent, translation: t, rotation: r, scale: s, inverseBindPose: matrix())
        }
        let vertexBytes = vertexCount * Self.vertexStride, indexBytes = indexCount * 4
        guard joints.indices.allSatisfy({ joints[$0].parent < $0 }), data.count >= offset + vertexBytes + indexBytes,
              let vertices = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress! + offset, length: vertexBytes) }),
              let indices = data.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress! + offset + vertexBytes, length: indexBytes)
              })
        else { return nil }
        (self.vertices, self.indices, self.indexCount, self.joints) = (vertices, indices, indexCount, joints)
        dots = Self.dots(joints: joints, instance: instance)
    }

    /// The menu hand's dots (Goddard's hand_open, the file select's pointer): three in a row across the back of the
    /// hand, just behind the knuckles, close together in the middle of it, each about a tenth of the hand across.
    /// Placed by the glove's rest skeleton (palm down, the back of the hand up: the anchor's +y), so they sit alike
    /// on the left glove and on the right, its mirror.
    private static func dots(joints: [Joint], instance: simd_float4x4) -> Dots {
        var model = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.count)
        for (i, joint) in joints.enumerated() {
            let local = translate(joint.translation) * simd_float4x4(joint.rotation)
                * simd_float4x4(diagonal: SIMD4(joint.scale, 1))
            model[i] = joint.parent >= 0 ? model[joint.parent] * local : local
        }
        // (the skeleton's joints: the index's metacarpal and knuckle 5 and 6, the middle's 10 and 11, the ring's 16)
        func at(_ i: Int) -> SIMD3<Float> { let p = instance * model[i].columns.3; return SIMD3(p.x, p.y, p.z) }
        let up = SIMD3<Float>(0, 1, 0)
        func flat(_ v: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(v - up * simd_dot(v, up)) }
        let across = flat(at(6) - at(16))  // (along the knuckles, as the menu hand's dots slant with them)
        let along = simd_cross(up, across)
        let middle = at(10) + (at(11) - at(10)) * 0.62
        let spacing: Float = 0.014, radius: Float = 0.0042  // (metres)
        // Into the mesh's own space, where glove_vertex hands glove_fragment the bound point
        let meshFromRest = instance.inverse
        func point(_ p: SIMD3<Float>) -> SIMD4<Float> { let q = meshFromRest * SIMD4(p, 1); return SIMD4(q.x, q.y, q.z, 0) }
        func direction(_ d: SIMD3<Float>) -> SIMD4<Float> {
            let q = meshFromRest * SIMD4(d, 0)
            return SIMD4(simd_normalize(SIMD3(q.x, q.y, q.z)), 0)
        }
        let scale = 1 / simd_length(SIMD3(instance.columns.0.x, instance.columns.0.y, instance.columns.0.z))
        return Dots(center: (point(middle + across * spacing), point(middle), point(middle - across * spacing)),
                    across: direction(across), along: direction(along), up: direction(up),
                    size: SIMD4(radius * scale, radius * 1.25 * scale, 0, 0))
    }

    /// Each joint's skinning matrix (bind pose to room metres) for `hand`, if it's a tracked hand
    func skin(_ hand: HandState) -> [simd_float4x4]? {
        var anchor = hand.anchor
        var rotations = hand.jointRotations
        #if DEBUG
        // (the simulator's scripted hands: the glove at rest, laid along their skeleton)
        if anchor == nil, let a = HandState.debugAnchor(hand.joints) {
            anchor = a
            rotations = joints.map(\.rotation)  // (at rest its fingers run along the anchor's -z, its palm down)
        }
        #endif
        guard let anchor, rotations.count == joints.count else { return nil }
        var model = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.count)
        for (i, joint) in joints.enumerated() {
            let local = Self.translate(joint.translation) * simd_float4x4(rotations[i])
                * simd_float4x4(diagonal: SIMD4(joint.scale, 1))
            model[i] = joint.parent >= 0 ? model[joint.parent] * local : local
        }
        let placed = anchor * instance
        return joints.indices.map { placed * model[$0] * joints[$0].inverseBindPose }
    }

    private static func translate(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }
}

#if DEBUG
extension HandState {
    /// (the simulator's scripted hands) a hand anchor for `joints` (debugJoints'): at the wrist, its -z along the
    /// hand to the middle knuckle, its y as near up as that allows
    static func debugAnchor(_ joints: [SIMD3<Float>]) -> simd_float4x4? {
        guard joints.count == jointNames.count else { return nil }
        let wrist = joints[0], along = joints[12] - wrist
        guard simd_length(along) > 1e-4 else { return nil }
        let z = -simd_normalize(along)
        var y = SIMD3<Float>(0, 1, 0) - z * z.y
        y = simd_length(y) > 1e-4 ? simd_normalize(y) : SIMD3(0, 0, 1)
        let x = simd_cross(y, z)
        return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(wrist, 1))
    }
}
#endif
