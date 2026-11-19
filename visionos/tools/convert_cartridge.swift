// Turns c4m5ron's "N64 Donkey Kong Cartridge" (Sketchfab, CC BY 4.0) into the cartridge shell the app draws
// (Mario64MR/Cartridge/Cartridge.shell): its shape only, none of its textures (the app paints it its own grey and
// puts its own label in the label's recess).
//
//   swiftc -O convert_cartridge.swift -o convert_cartridge
//   ./convert_cartridge n64_donkey_kong_cartridge.glb ../Mario64MR/Cartridge/Cartridge.shell
//
// The shell is laid out as the app's cartridge is (Cartridge.size, metres): centred, x right, y up (its connector
// down), z out of its front (the label's side), and scaled to the app's width.
//
// A .shell file, LZFSE-compressed (little-endian):
//   "SHL1", vertex count, index count (UInt32 each)
//   the label's recess: its centre (x, y), its half size (x, y), and its depth's z (5 floats)
//   each vertex as PropVertex: position (3 floats), normal (3 floats), uv (2 floats, 0)
//   the triangles' indices (UInt16)

import Foundation
import simd

struct GLB {
    let json: [String: Any]
    let bin: Data

    init(_ data: Data) throws {
        func u32(_ at: Int) -> Int { Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }) }
        guard data.count > 20, u32(0) == 0x4654_6C67 else { throw Failure("not a .glb") }
        let jsonLength = u32(12)
        json = try JSONSerialization.jsonObject(with: data.subdata(in: 20..<20 + jsonLength)) as! [String: Any]
        let binAt = 20 + jsonLength
        bin = data.subdata(in: binAt + 8..<binAt + 8 + u32(binAt))
    }

    func list(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }

    /// An accessor's values, as floats (indices too), `components` a value
    func accessor(_ index: Int) -> (values: [Float], components: Int) {
        let a = list("accessors")[index], view = list("bufferViews")[a["bufferView"] as! Int]
        let count = a["count"] as! Int
        let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][a["type"] as! String]!
        let type = a["componentType"] as! Int
        let size = [5126: 4, 5125: 4, 5123: 2, 5121: 1][type]!
        let start = (view["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
        let stride = view["byteStride"] as? Int ?? components * size
        var values: [Float] = []
        values.reserveCapacity(count * components)
        bin.withUnsafeBytes { raw in
            for i in 0..<count {
                for c in 0..<components {
                    let at = start + i * stride + c * size
                    switch type {
                    case 5126: values.append(raw.loadUnaligned(fromByteOffset: at, as: Float.self))
                    case 5125: values.append(Float(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                    case 5123: values.append(Float(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)))
                    default: values.append(Float(raw.load(fromByteOffset: at, as: UInt8.self)))
                    }
                }
            }
        }
        return (values, components)
    }

    /// Each mesh node's transform into the scene (its parents' matrices applied)
    func meshNodes() -> [(mesh: Int, transform: simd_double4x4)] {
        let nodes = list("nodes")
        var out: [(Int, simd_double4x4)] = []
        func visit(_ i: Int, _ parent: simd_double4x4) {
            let node = nodes[i]
            var local = matrix_identity_double4x4
            if let m = node["matrix"] as? [Double] {
                local = simd_double4x4((0..<4).map { SIMD4(m[$0 * 4], m[$0 * 4 + 1], m[$0 * 4 + 2], m[$0 * 4 + 3]) })
            } else if node["translation"] != nil || node["rotation"] != nil || node["scale"] != nil {
                let t = node["translation"] as? [Double] ?? [0, 0, 0], r = node["rotation"] as? [Double] ?? [0, 0, 0, 1]
                let s = node["scale"] as? [Double] ?? [1, 1, 1]
                var T = matrix_identity_double4x4
                T.columns.3 = SIMD4(t[0], t[1], t[2], 1)
                local = T * simd_double4x4(simd_quatd(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
                    * simd_double4x4(diagonal: SIMD4(s[0], s[1], s[2], 1))
            }
            let world = parent * local
            if let mesh = node["mesh"] as? Int { out.append((mesh, world)) }
            for child in node["children"] as? [Int] ?? [] { visit(child, world) }
        }
        let scene = list("scenes")[json["scene"] as? Int ?? 0]
        for root in scene["nodes"] as? [Int] ?? [] { visit(root, matrix_identity_double4x4) }
        return out
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: convert_cartridge <the .glb> [<out .shell>]"); exit(1) }
let glb = try GLB(Data(contentsOf: URL(fileURLWithPath: args[1])))
guard let (meshIndex, transform) = glb.meshNodes().first else { throw Failure("no mesh") }
let primitive = (glb.list("meshes")[meshIndex]["primitives"] as! [[String: Any]])[0]
let attributes = primitive["attributes"] as! [String: Int]
let rawPositions = glb.accessor(attributes["POSITION"]!).values
let rawNormals = glb.accessor(attributes["NORMAL"]!).values
let indices = glb.accessor(primitive["indices"] as! Int).values.map { Int($0) }
let turn = simd_double3x3(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                          SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                          SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
var positions = stride(from: 0, to: rawPositions.count, by: 3).map { i -> SIMD3<Double> in
    let p = transform * SIMD4(Double(rawPositions[i]), Double(rawPositions[i + 1]), Double(rawPositions[i + 2]), 1)
    return SIMD3(p.x, p.y, p.z)
}
var normals = stride(from: 0, to: rawNormals.count, by: 3).map {
    simd_normalize(turn * SIMD3(Double(rawNormals[$0]), Double(rawNormals[$0 + 1]), Double(rawNormals[$0 + 2])))
}
let lo = positions.reduce(SIMD3(repeating: Double.infinity)) { simd_min($0, $1) }
let hi = positions.reduce(SIMD3(repeating: -Double.infinity)) { simd_max($0, $1) }
print("\(positions.count) vertices, \(indices.count / 3) triangles; in the scene from \(lo) to \(hi), size \(hi - lo)")

// Into the app's cartridge space: across (the scene's z), up (its -y: its connector is at +y, where it's narrower),
// out of the front (its x: the label's recess is on +x). Scaled to the app's width, and its thickness to a real
// cartridge's for that width (11.6 × 7.66 × 1.85 cm: the model is half as thick)
let width = 0.124, realThickness = 0.0185 / 0.116
let across = hi.z - lo.z, center = (lo + hi) / 2
let s = SIMD3(width / across, width / across, width * realThickness / (hi.x - lo.x))
func place(_ p: SIMD3<Double>) -> SIMD3<Double> { let q = p - center; return SIMD3(q.z, -q.y, q.x) * s }
func turnNormal(_ n: SIMD3<Double>) -> SIMD3<Double> { simd_normalize(SIMD3(n.z, -n.y, n.x) / s) }
positions = positions.map(place)
normals = normals.map(turnNormal)
let size = positions.reduce(SIMD3(repeating: 0.0)) { simd_max($0, abs($1)) } * 2
print(String(format: "the shell: %.4f × %.4f × %.4f m", size.x, size.y, size.z))

// The label's recess: the biggest of the front's flat faces set back from its frontmost ones
var depths = [Int: (area: Double, lo: SIMD2<Double>, hi: SIMD2<Double>)]()
for t in stride(from: 0, to: indices.count, by: 3) {
    let a = positions[indices[t]], b = positions[indices[t + 1]], c = positions[indices[t + 2]]
    let n = simd_cross(b - a, c - a), l = simd_length(n)
    guard l > 0, n.z / l > 0.98 else { continue }
    let key = Int(((a.z + b.z + c.z) / 3 * 1e4).rounded())  // (tenths of a millimetre)
    var d = depths[key] ?? (0, SIMD2(repeating: .infinity), SIMD2(repeating: -.infinity))
    d.area += l / 2
    for p in [a, b, c] { d.lo = simd_min(d.lo, SIMD2(p.x, p.y)); d.hi = simd_max(d.hi, SIMD2(p.x, p.y)) }
    depths[key] = d
}
for (k, d) in depths.sorted(by: { $0.key < $1.key }) where d.area > 1e-6 {
    print(String(format: "  front faces at z %.4f: %.1f cm², x %.4f…%.4f, y %.4f…%.4f", Double(k) / 1e4, d.area * 1e4, d.lo.x, d.hi.x, d.lo.y, d.hi.y))
}
guard let frontmost = depths.filter({ $0.value.area > size.x * size.y * 0.1 }).keys.max(),
      let recessKey = depths.filter({ $0.key < frontmost - 10 }).max(by: { $0.value.area < $1.value.area })?.key,
      let recess = depths[recessKey] else { throw Failure("no label recess") }  // (1 mm back, at least)
let labelCenter = (recess.lo + recess.hi) / 2, labelHalf = (recess.hi - recess.lo) / 2
print(String(format: "the label's recess: centre (%.4f, %.4f), %.4f × %.4f m, at z %.4f (the front at %.4f)",
             labelCenter.x, labelCenter.y, labelHalf.x * 2, labelHalf.y * 2, Double(recessKey) / 1e4, Double(frontmost) / 1e4))

guard args.count >= 3 else { exit(0) }
guard positions.count <= 65536 else { throw Failure("too many vertices for 16-bit indices") }
var data = Data("SHL1".utf8)
func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
put(UInt32(positions.count)); put(UInt32(indices.count))
for v in [labelCenter.x, labelCenter.y, labelHalf.x, labelHalf.y, Double(recessKey) / 1e4] { put(Float(v)) }
for (p, n) in zip(positions, normals) {
    for v in [p.x, p.y, p.z, n.x, n.y, n.z, 0, 0] { put(Float(v)) }
}
for i in indices { put(UInt16(i)) }
let packed = try (data as NSData).compressed(using: .lzfse) as Data
try packed.write(to: URL(fileURLWithPath: args[2]))
print("\(args[2]): \(packed.count / 1024) KB (\(data.count / 1024) KB unpacked)")
