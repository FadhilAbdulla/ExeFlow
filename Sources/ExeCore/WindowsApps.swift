import Foundation

public struct WindowsApp: Hashable, Sendable {
    public var name: String
    public var program: URL
}

/// Real applications are the ones with a Start-menu or desktop shortcut; helper .exe files don't have one.
public enum WindowsApps {
    public static func list(in environment: URL) -> [WindowsApp] {
        let root = environment.appendingPathComponent("drive_c")
        var found: [WindowsApp] = []
        var seen = Set<String>()
        for folder in shortcutFolders(root) {
            guard let walker = FileManager.default.enumerator(atPath: folder.path) else { continue }
            for case let path as String in walker where path.lowercased().hasSuffix(".lnk") {
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(path)),
                      let target = shortcutTarget(data), let file = unixPath(target, root: root) else { continue }
                let exe = file.lastPathComponent.lowercased()
                guard exe.hasSuffix(".exe"), !exe.hasPrefix("unins"), !exe.hasPrefix("uninst"),
                      !name.lowercased().contains("uninstall"),
                      !target.lowercased().hasPrefix("c:\\windows\\"),
                      FileManager.default.fileExists(atPath: file.path),
                      seen.insert(file.path.lowercased()).inserted else { continue }
                found.append(WindowsApp(name: name, program: file))
            }
        }
        if found.isEmpty { // Some installers create no shortcut.
            found = InstalledPrograms.list(in: environment).map {
                WindowsApp(name: $0.deletingPathExtension().lastPathComponent, program: $0)
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func shortcutFolders(_ root: URL) -> [URL] {
        var folders = [root.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu")]
        let users = root.appendingPathComponent("users")
        for user in (try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            folders.append(user.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu"))
            folders.append(user.appendingPathComponent("Desktop"))
        }
        return folders
    }

    /// Reads the local path from a Windows shortcut (MS-SHLLINK). Untrusted input.
    public static func shortcutTarget(_ data: Data) -> String? {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            guard let lo = u16(o), let hi = u16(o + 2) else { return nil }
            return lo | hi << 16
        }
        guard u32(0) == 0x4C, let flags = u32(0x14), flags & 2 != 0 else { return nil }
        var at = 0x4C
        if flags & 1 != 0 {
            guard let size = u16(at) else { return nil }
            at += 2 + size
        }
        guard let header = u32(at + 4), let kind = u32(at + 8), kind & 1 != 0 else { return nil }
        if header >= 0x24, let offset = u32(at + 0x1C), offset > 0 {
            var units: [UInt16] = [], o = at + offset
            while let c = u16(o), c != 0, units.count < 1024 { units.append(UInt16(c)); o += 2 }
            if !units.isEmpty { return String(decoding: units, as: UTF16.self) }
        }
        guard let offset = u32(at + 0x10), offset > 0, at + offset < b.count else { return nil }
        let text = b[(at + offset)...].prefix(1024).prefix { $0 != 0 }
        return String(bytes: text, encoding: .utf8) ?? String(bytes: text, encoding: .windowsCP1252)
    }

    /// Only drive C: paths inside the environment are accepted.
    static func unixPath(_ path: String, root: URL) -> URL? {
        guard path.lowercased().hasPrefix("c:\\") else { return nil }
        let parts = path.dropFirst(3).split(separator: "\\").map(String.init)
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }
}
