import Foundation
import Metal
import simd

/// The cartridge's shell: c4m5ron's "N64 Donkey Kong Cartridge" (CC BY 4.0, see Cartridge/Cartridge-LICENSE.txt),
/// only its shape (Cartridge/Cartridge.shell, made by tools/convert_cartridge.swift), in the cartridge's own space
/// (Cartridge.size, metres: x across, y up, z out of its front), drawn in RoomProps' grey plastic
final class CartridgeShell {
    /// PropVertex: position (3 floats), normal (3 floats), uv (2 floats)
    let vertices: MTLBuffer
    /// UInt16
    let indices: MTLBuffer
    let indexCount: Int
    /// The label's recess on the front: its centre, half its size, and how far out of the middle it is
    let labelCenter: SIMD2<Float>, labelHalf: SIMD2<Float>, labelZ: Float

    init?(device: MTLDevice, url: URL) {
        guard let packed = try? Data(contentsOf: url),
              let data = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              data.count > 32, data.prefix(4) == Data("SHL1".utf8) else { return nil }
        func float(_ i: Int) -> Float { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12 + i * 4, as: Float.self) } }
        let (vertexCount, indexCount) = data.withUnsafeBytes {
            (Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)), Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
        }
        let start = 32, vertexBytes = vertexCount * 32, indexBytes = indexCount * 2
        guard data.count >= start + vertexBytes + indexBytes,
              let vertices = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress! + start, length: vertexBytes) }),
              let indices = data.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress! + start + vertexBytes, length: indexBytes)
              })
        else { return nil }
        (self.vertices, self.indices, self.indexCount) = (vertices, indices, indexCount)
        (labelCenter, labelHalf, labelZ) = (SIMD2(float(0), float(1)), SIMD2(float(2), float(3)), float(4))
    }
}
