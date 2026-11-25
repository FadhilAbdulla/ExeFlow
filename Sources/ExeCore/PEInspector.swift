import Foundation

public enum InspectionError: LocalizedError {
    case notWindowsExecutable, truncated
    public var errorDescription: String? {
        switch self {
        case .notWindowsExecutable: return "This file is not a Windows program."
        case .truncated: return "This file is damaged or incomplete."
        }
    }
}

public struct PEInfo: Equatable, Sendable {
    public enum Architecture: String, Sendable { case x86 = "32-bit Intel", x64 = "64-bit Intel", arm64 = "ARM64", other = "Unknown" }
    public var architecture: Architecture
    public var subsystem: UInt16
    public var isDotNet: Bool
    public var imports: [String]
    /// Subsystem 1 is NATIVE: kernel drivers and boot programs.
    public var isDriver: Bool { subsystem == 1 }
    public var isConsole: Bool { subsystem == 3 }
}

/// Reads PE headers without executing anything. Input is untrusted, so every read is bounds-checked.
public enum PEInspector {
    public static func inspect(_ url: URL) throws -> PEInfo {
        try inspect(Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func inspect(_ data: Data) throws -> PEInfo {
        let r = Reader(data: data)
        guard data.count >= 64, try r.u16(0) == 0x5A4D else { throw InspectionError.notWindowsExecutable }
        let pe = Int(try r.u32(0x3C))
        guard try r.u32(pe) == 0x0000_4550 else { throw InspectionError.notWindowsExecutable }
        let machine = try r.u16(pe + 4)
        let sectionCount = Int(try r.u16(pe + 6))
        let optionalSize = Int(try r.u16(pe + 20))
        let opt = pe + 24
        let magic = try r.u16(opt)
        guard magic == 0x10B || magic == 0x20B else { throw InspectionError.notWindowsExecutable }
        let plus = magic == 0x20B
        let subsystem = try r.u16(opt + 68)
        let dirCount = Int(try r.u32(opt + (plus ? 108 : 92)))
        let dirs = opt + (plus ? 112 : 96)

        func directory(_ i: Int) throws -> UInt32 {
            let end = dirs + i * 8 + 8
            guard i < dirCount, end <= opt + optionalSize else { return 0 }
            return try r.u32(dirs + i * 8)
        }
        var sections: [(va: Int, size: Int, raw: Int)] = []
        for i in 0..<sectionCount {
            let s = opt + optionalSize + i * 40
            sections.append((Int(try r.u32(s + 12)),
                             max(Int(try r.u32(s + 8)), Int(try r.u32(s + 16))),
                             Int(try r.u32(s + 20))))
        }
        func offset(_ rva: Int) -> Int? {
            sections.first { rva >= $0.va && rva < $0.va + $0.size }.map { $0.raw + rva - $0.va }
        }

        // Packed files can have unreadable import tables; that must not block inspection.
        var imports: [String] = []
        let importRVA = Int(try directory(1))
        if importRVA != 0, var at = offset(importRVA) {
            for _ in 0..<512 {
                guard let nameRVA = try? r.u32(at + 12), nameRVA != 0,
                      let nameAt = offset(Int(nameRVA)), let name = r.cString(nameAt) else { break }
                imports.append(name.lowercased())
                at += 20
            }
        }
        let arch: PEInfo.Architecture
        switch machine {
        case 0x14C: arch = .x86
        case 0x8664: arch = .x64
        case 0xAA64: arch = .arm64
        default: arch = .other
        }
        return PEInfo(architecture: arch, subsystem: subsystem, isDotNet: try directory(14) != 0, imports: imports)
    }

    private struct Reader {
        let data: Data
        func u16(_ o: Int) throws -> UInt16 {
            guard o >= 0, o + 2 <= data.count else { throw InspectionError.truncated }
            let b = data.startIndex + o
            return UInt16(data[b]) | UInt16(data[b + 1]) << 8
        }
        func u32(_ o: Int) throws -> UInt32 {
            UInt32(try u16(o)) | UInt32(try u16(o + 2)) << 16
        }
        func cString(_ o: Int) -> String? {
            guard o >= 0, o < data.count else { return nil }
            let slice = data.dropFirst(o).prefix(256)
            guard let end = slice.firstIndex(of: 0), end > slice.startIndex else { return nil }
            return String(data: slice[slice.startIndex..<end], encoding: .ascii)
        }
    }
}

extension PEInspector {
    /// The program's own icon as .ico data.
    public static func icon(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? icon(data)
    }

    static func icon(_ data: Data) throws -> Data? {
        let r = Reader(data: data)
        guard data.count >= 64, try r.u16(0) == 0x5A4D else { return nil }
        let pe = Int(try r.u32(0x3C)), opt = pe + 24
        let count = Int(try r.u16(pe + 6)), optionalSize = Int(try r.u16(pe + 20))
        let dir = opt + (try r.u16(opt) == 0x20B ? 112 : 96) + 16
        let rva = Int(try r.u32(dir))
        var sections: [(va: Int, size: Int, raw: Int)] = []
        for i in 0..<count {
            let s = opt + optionalSize + i * 40
            sections.append((Int(try r.u32(s + 12)), max(Int(try r.u32(s + 8)), Int(try r.u32(s + 16))), Int(try r.u32(s + 20))))
        }
        func offset(_ rva: Int) -> Int? { sections.first { rva >= $0.va && rva < $0.va + $0.size }.map { $0.raw + rva - $0.va } }
        guard rva != 0, let base = offset(rva) else { return nil }
        func entries(_ at: Int) throws -> [(id: UInt32, to: Int)] {
            let n = min(Int(try r.u16(at + 12)) + Int(try r.u16(at + 14)), 4096)
            return try (0..<n).map { (try r.u32(at + 16 + $0 * 8), Int(try r.u32(at + 20 + $0 * 8) & 0x7FFF_FFFF)) }
        }
        func blob(_ at: Int) throws -> Data? { // name directory -> first language -> data
            guard let lang = try entries(at).first, let start = offset(Int(try r.u32(base + lang.to))) else { return nil }
            let size = Int(try r.u32(base + lang.to + 4))
            guard size > 0, start + size <= data.count else { return nil }
            return data.subdata(in: data.startIndex + start..<data.startIndex + start + size)
        }
        let types = try entries(base)
        guard let groups = types.first(where: { $0.id == 14 }), let icons = types.first(where: { $0.id == 3 }),
              let first = try entries(base + groups.to).first, let group = try blob(base + first.to) else { return nil }
        let g = Reader(data: group), iconList = try entries(base + icons.to)
        var images: [(head: Data, body: Data)] = []
        for i in 0..<min(Int(try g.u16(4)), 64) {
            let e = 6 + i * 14
            guard e + 14 <= group.count, let found = iconList.first(where: { $0.id == UInt32((try? g.u16(e + 12)) ?? 0) }),
                  let body = try blob(base + found.to) else { continue }
            images.append((group.subdata(in: e..<e + 8), body))
        }
        guard !images.isEmpty else { return nil }
        func le(_ v: Int, _ n: Int) -> Data { Data((0..<n).map { UInt8((v >> (8 * $0)) & 255) }) }
        var head = le(0, 2) + le(1, 2) + le(images.count, 2), bodies = Data()
        for image in images {
            head += image.head + le(image.body.count, 4) + le(6 + 16 * images.count + bodies.count, 4)
            bodies += image.body
        }
        return head + bodies
    }

    /// Recognises common installers, so the app can say "Install" instead of "Open".
    public static func looksLikeInstaller(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "msi" { return true }
        let name = url.lastPathComponent.lowercased()
        if name.contains("setup") || name.contains("install") { return true }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return ["Inno Setup", "Nullsoft", "InstallShield", "WixBundle"].contains { data.range(of: Data($0.utf8)) != nil }
    }
}

public struct Prediction: Equatable, Sendable {
    public enum Level: String, Sendable { case likely = "May work", uncertain = "Uncertain", unsupported = "Not supported" }
    public var level: Level
    public var notes: [String]

    /// A heuristic from file headers, not a guarantee.
    public static func make(for info: PEInfo) -> Prediction {
        if info.isDriver { return .init(level: .unsupported, notes: ["This is a driver or boot program. It needs real Windows."]) }
        if info.architecture == .arm64 { return .init(level: .unsupported, notes: ["This is a Windows-on-ARM program. The current engine runs Intel programs."]) }
        if info.architecture == .other { return .init(level: .unsupported, notes: ["This processor type is not supported."]) }
        var notes: [String] = []
        if info.architecture == .x86 { notes.append("32-bit program. Needs the engine's Rosetta fix; some may still fail.") }
        if info.isDotNet { notes.append("Uses .NET. Compatibility varies.") }
        if info.imports.contains(where: { $0.hasPrefix("d3d1") || $0.hasPrefix("dxgi") }) {
            notes.append("Uses Direct3D 10 or later, which this engine does not support yet. It will probably not start.")
        }
        return .init(level: notes.isEmpty ? .likely : .uncertain, notes: notes)
    }
}
