import Foundation
import Observation

/// Texture packs (sm64ex's: a zip or a folder with gfx/ in it, the game's textures by name as PNGs, any size), kept
/// in the app's Documents folder as zips, which the game mounts over base.zip when it starts (sm64ex's file system:
/// the zips in the save folder's res/, in name order, the later winning; it mounts no folders there):
/// - on: Documents/sm64/res/<pack>.zip
/// - off: Documents/sm64/res-off/<pack>.zip (the game doesn't look there)
/// A zip with gfx/ at its top is kept as it is; one with gfx/ inside a folder, and a folder, are zipped again from
/// where gfx/ is. Changes apply when the game next starts.
@MainActor @Observable
final class TexturePacks {
    struct Pack: Identifiable, Equatable {
        var id: String { file }
        let file: String       // its name in res/ or res-off/
        let enabled: Bool
        let bytes: Int64
        var name: String { String(file.dropLast(4)) }
    }

    nonisolated static let saves = URL.documentsDirectory.appendingPathComponent("sm64")
    nonisolated static let on = saves.appendingPathComponent("res")
    nonisolated static let off = saves.appendingPathComponent("res-off")

    private(set) var packs: [Pack] = []
    /// Changed since the game started: it uses them from its next start
    private(set) var changed = false
    private(set) var importing = false
    var problem: String?

    init() { reload() }

    func reload() {
        var found: [Pack] = []
        for (folder, enabled) in [(Self.on, true), (Self.off, false)] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in files where !file.hasPrefix(".") && Self.isPack(folder.appendingPathComponent(file)) {
                found.append(Pack(file: file, enabled: enabled, bytes: Self.size(of: folder.appendingPathComponent(file))))
            }
        }
        // (the game's order: strcmp, the later winning)
        packs = found.sorted { Array($0.file.utf8).lexicographicallyPrecedes(Array($1.file.utf8)) }
    }

    /// A zip or folder from the Files app (the file importer's), copied in, on
    func add(_ url: URL) {
        importing = true
        problem = nil
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { try Self.install(url) }
            await MainActor.run {
                self.importing = false
                if case .failure(let error) = result { self.problem = error.localizedDescription }
                else { self.changed = true }
                self.reload()
            }
        }
    }

    func setEnabled(_ pack: Pack, _ enabled: Bool) {
        guard pack.enabled != enabled else { return }
        let from = (pack.enabled ? Self.on : Self.off).appendingPathComponent(pack.file)
        let to = enabled ? Self.on : Self.off
        do {
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: from, to: Self.unused(pack.file, in: to))
            changed = true
        } catch { problem = error.localizedDescription }
        reload()
    }

    func remove(_ pack: Pack) {
        do {
            try FileManager.default.removeItem(at: (pack.enabled ? Self.on : Self.off).appendingPathComponent(pack.file))
            changed = true
        } catch { problem = error.localizedDescription }
        reload()
    }

    // ---------------------------------------------------------------- Installing

    enum Problem: LocalizedError {
        case notAPack(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .notAPack(let name): "\(name) isn't a texture pack: there's no gfx folder in it"
            case .unreadable(let name): "\(name) couldn't be read (a zip over 4 GB, or packed in a way it doesn't know)"
            }
        }
    }

    nonisolated private static func install(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: on, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        var isFolder: ObjCBool = false
        _ = fm.fileExists(atPath: url.path, isDirectory: &isFolder)
        if isFolder.boolValue {
            guard let top = packTop(in: url) else { throw Problem.notAPack(name) }
            var files: [(String, URL)] = []
            let walk = fm.enumerator(at: top, includingPropertiesForKeys: [.isRegularFileKey])
            while let file = walk?.nextObject() as? URL {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      !file.lastPathComponent.hasPrefix(".") else { continue }
                let path = file.standardizedFileURL.path.dropFirst(top.standardizedFileURL.path.count + 1)
                files.append((String(path), file))
            }
            try writeZip(files.map { file in (file.0, { try Data(contentsOf: file.1, options: .mappedIfSafe) }) },
                         to: unused(packName(url.lastPathComponent) + ".zip", in: on), name: name)
            return
        }
        guard let zip = ZipArchive(url: url) else { throw Problem.unreadable(name) }
        let names = zip.names.filter { !$0.hasPrefix("__MACOSX/") }
        // Where gfx/ (or sound/) is: the zip's top, or a folder in it (the shortest such)
        let prefixes = names.compactMap { entry -> String? in
            for top in ["gfx/", "sound/"] {
                if entry.hasPrefix(top) { return "" }
                if let r = entry.range(of: "/" + top) { return String(entry[..<r.lowerBound]) + "/" }
            }
            return nil
        }
        guard let prefix = prefixes.min(by: { $0.count < $1.count }) else { throw Problem.notAPack(name) }
        let stem = (name as NSString).deletingPathExtension
        if prefix.isEmpty {  // (as it is: the game reads zips)
            try fm.copyItem(at: url, to: unused(packName(stem) + ".zip", in: on))
            return
        }
        // gfx/ in a folder: zipped again from that folder
        let entries = names.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("/") }.map { entry in
            (String(entry.dropFirst(prefix.count)), { () throws -> Data in
                guard let data = zip.read(entry) else { throw Problem.unreadable(name) }
                return data
            })
        }
        try writeZip(entries, to: unused(packName(stem) + ".zip", in: on), name: name)
    }

    /// A zip of these files (stored: PNGs are compressed already), written a file at a time; through a temporary
    /// file, so a pack is never half there
    nonisolated private static func writeZip(_ files: [(path: String, data: () throws -> Data)], to url: URL,
                                             name: String) throws {
        let fm = FileManager.default
        guard files.count < 65_535 else { throw Problem.unreadable(name) }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".importing-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: nil),
              let out = try? FileHandle(forWritingTo: temporary) else { throw Problem.unreadable(name) }
        defer { try? out.close(); try? fm.removeItem(at: temporary) }
        var central = Data(), offset = 0
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { Data($0) } }
        for file in files.sorted(by: { $0.path < $1.path }) {
            let data = try autoreleasepool { try file.data() }
            let path = Data(file.path.utf8), crc = Int(crc32(data))
            guard offset + data.count + 30 + path.count < Int(UInt32.max) else { throw Problem.unreadable(name) }
            // version 20, flags 0x800 (UTF-8 names), stored, no time
            let common = le16(20) + le16(0x800) + le16(0) + le16(0) + le16(0x21)
                + le32(crc) + le32(data.count) + le32(data.count) + le16(path.count) + le16(0)
            try out.write(contentsOf: le32(0x0403_4b50) + common + path)
            try out.write(contentsOf: data)
            central += le32(0x0201_4b50) + le16(20) + common + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset)
                + path
            offset += 30 + path.count + data.count
        }
        try out.write(contentsOf: central)
        try out.write(contentsOf: le32(0x0605_4b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
                      + le32(central.count) + le32(offset) + le16(0))
        try out.close()
        try fm.moveItem(at: temporary, to: url)
    }

    nonisolated private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    nonisolated private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }

    /// The folder with gfx/ (or sound/) in it: this one, or one a few levels down
    nonisolated private static func packTop(in url: URL, depth: Int = 0) -> URL? {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let folders = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if folders.contains(where: { ["gfx", "sound"].contains($0.lastPathComponent.lowercased()) }) { return url }
        guard depth < 3 else { return nil }
        return folders.lazy.compactMap { packTop(in: $0, depth: depth + 1) }.first
    }

    /// (names starting "base" the game mounts first, under base.zip: not those)
    nonisolated private static func packName(_ name: String) -> String {
        name.lowercased().hasPrefix("base") ? "pack " + name : name
    }

    nonisolated private static func unused(_ file: String, in folder: URL) -> URL {
        let ext = (file as NSString).pathExtension, stem = (file as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(file), n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }

    nonisolated private static func isPack(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    nonisolated private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // ---------------------------------------------------------------- Reading (the title screen's face)

    /// The packs on, as the game mounts them, the winning first: a file from the first that has it
    struct Reader {
        private let sources: [ZipArchive]

        init() {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: TexturePacks.on.path)) ?? []
            let sorted = files.filter { !$0.hasPrefix(".") }
                .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            sources = sorted.reversed().compactMap { file in
                let url = TexturePacks.on.appendingPathComponent(file)
                return TexturePacks.isPack(url) ? ZipArchive(url: url) : nil
            }
        }

        var isEmpty: Bool { sources.isEmpty }

        func read(_ path: String) -> Data? {
            sources.lazy.compactMap { $0.read(path) }.first
        }
    }
}
