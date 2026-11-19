// Turns the gloves of Apple's "Animating hand models in visionOS" sample (MIT; LeftGlove.usdz, RightGlove.usdz) into
// the small files the app draws Mario's gloves from (Mario64MR/Gloves/*.glove): only their shape and their bones,
// none of their textures. Loaded with RealityKit as the sample loads them, so the skinning is what RealityKit does,
// but for the mesh's geomBindTransform (its points into the skeleton's space at bind), which RealityKit's mesh
// contents leave out: read with usdcat (Xcode's command line tools) and baked into the points.
//
//   swiftc -O convert_gloves.swift -o convert_gloves
//   ./convert_gloves path/to/AnimatingHandModels/models ../Mario64MR/Gloves
//
// A .glove file, LZFSE-compressed (little-endian):
//   "GLV1", vertex count, index count, joint count (UInt32 each)
//   the mesh's place in the model (float4x4: skeleton centimetres to model metres)
//   each joint (the ARKit hand skeleton's order): parent (Int32, -1 none), rest translation (3 floats), rest rotation
//     (4: imaginary xyz, real), rest scale (3), inverse bind pose (float4x4)
//   each vertex: position (3 floats, skeleton centimetres, bound), normal (3 floats), joints (4 bytes), weights (4 bytes,
//     summing to 255)
//   the triangles' indices (UInt32)

import Foundation
import RealityKit

/// The skinned mesh's primvars:skel:geomBindTransform (USD's rows, so simd's columns)
func geomBind(_ url: URL) throws -> simd_float4x4 {
    let usdcat = Process()
    usdcat.executableURL = URL(fileURLWithPath: "/usr/bin/usdcat")
    usdcat.arguments = ["--flatten", url.path]
    let pipe = Pipe()
    usdcat.standardOutput = pipe
    try usdcat.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    usdcat.waitUntilExit()
    guard let line = text.range(of: #"geomBindTransform = \(.*\)"#, options: .regularExpression).map({ text[$0] })
    else { throw NSError(domain: "glove", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): no geomBindTransform"]) }
    let numbers = line.split(whereSeparator: { "(), =".contains($0) }).compactMap { Float($0) }
    guard numbers.count == 16 else { throw NSError(domain: "glove", code: 3) }
    return simd_float4x4((0..<4).map { SIMD4(numbers[$0 * 4..<$0 * 4 + 4]) })
}

@MainActor func convert(_ url: URL, to out: URL) async throws {
    let bind = try geomBind(url)
    let turn = simd_float3x3(SIMD3(bind.columns.0.x, bind.columns.0.y, bind.columns.0.z),
                             SIMD3(bind.columns.1.x, bind.columns.1.y, bind.columns.1.z),
                             SIMD3(bind.columns.2.x, bind.columns.2.y, bind.columns.2.z))
    let glove = try await ModelEntity(contentsOf: url)
    let contents = glove.model!.mesh.contents
    guard let skeleton = contents.skeletons.first, skeleton.joints.count == 27,
          let instance = contents.instances.first,
          let part = contents.models[instance.model]?.parts.first,
          let normals = part.normals, let indices = part.triangleIndices, let influences = part.jointInfluences
    else { throw NSError(domain: "glove", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent): not as expected"]) }

    var data = Data()
    func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
    func put(_ m: simd_float4x4) { for c in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] { put(c.x); put(c.y); put(c.z); put(c.w) } }
    func put3(_ v: SIMD3<Float>) { put(v.x); put(v.y); put(v.z) }

    let positions = Array(part.positions), normalArray = Array(normals), influenceArray = Array(influences.influences)
    let perVertex = influenceArray.count / positions.count
    data.append(contentsOf: Array("GLV1".utf8))
    put(UInt32(positions.count)); put(UInt32(indices.count)); put(UInt32(skeleton.joints.count))
    put(instance.transform)
    for joint in skeleton.joints {
        let rest = joint.restPoseTransform
        put(Int32(joint.parentIndex ?? -1))
        put3(rest.translation)
        put(rest.rotation.imag.x); put(rest.rotation.imag.y); put(rest.rotation.imag.z); put(rest.rotation.real)
        put3(rest.scale)
        put(joint.inverseBindPoseMatrix)
    }
    for (i, p) in positions.enumerated() {
        let bound = bind * SIMD4(p, 1)
        put3(SIMD3(bound.x, bound.y, bound.z)); put3(simd_normalize(turn * normalArray[i]))
        // The four strongest, their weights in bytes summing to 255
        let mine = influenceArray[i * perVertex..<(i + 1) * perVertex].sorted { $0.weight > $1.weight }.prefix(4)
        let total = max(mine.reduce(0) { $0 + $1.weight }, 1e-6)
        var joints = [UInt8](repeating: 0, count: 4), weights = [UInt8](repeating: 0, count: 4)
        var left = 255
        for (k, influence) in mine.enumerated() {
            joints[k] = UInt8(influence.jointIndex)
            weights[k] = UInt8(k == mine.count - 1 ? left : min(left, Int((influence.weight / total * 255).rounded())))
            left -= Int(weights[k])
        }
        data.append(contentsOf: joints); data.append(contentsOf: weights)
    }
    for index in indices { put(UInt32(index)) }

    let packed = try (data as NSData).compressed(using: .lzfse) as Data
    try packed.write(to: out)
    print("\(out.lastPathComponent): \(positions.count) vertices, \(indices.count / 3) triangles, \(perVertex) influences a vertex, "
          + "\(skeleton.joints.count) joints, \(packed.count / 1024) KB (\(data.count / 1024) KB unpacked)")
}

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: convert_gloves <the sample's models folder> <out folder>"); exit(1) }
let from = URL(fileURLWithPath: args[1]), to = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
for name in ["LeftGlove", "RightGlove"] {
    try await convert(from.appendingPathComponent("\(name).usdz"), to: to.appendingPathComponent("\(name).glove"))
}
