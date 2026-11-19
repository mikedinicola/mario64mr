import Foundation
import Metal
import simd

/// Mario's gloves: the gloves of Apple's "Animating hand models in visionOS" sample (MIT, see
/// Gloves/Gloves-LICENSE.txt), only their shape and bones (Gloves/*.glove, made by tools/convert_gloves.swift),
/// drawn white by glove_fragment. Their 27 joints are the ARKit hand skeleton's, in its order, and rest as it does: as in the sample, each joint
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
