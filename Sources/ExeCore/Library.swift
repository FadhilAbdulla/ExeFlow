import Foundation

public struct ProgramItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Persists known programs; each gets its own Windows environment.
public final class Library {
    public let root: URL
    public private(set) var items: [ProgramItem] = []
    private var index: URL { root.appendingPathComponent("library.json") }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: index.path) {
            items = try JSONDecoder().decode([ProgramItem].self, from: Data(contentsOf: index))
        }
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ExeFlow")
    }

    /// Moves data from the app's former name, MacExeRunner. Never overwrites existing data.
    public static func migrate(from old: URL, to new: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try fm.moveItem(at: old, to: new)
    }

    @discardableResult
    public func add(_ url: URL) throws -> ProgramItem {
        let path = url.standardizedFileURL.path
        if let known = items.first(where: { $0.path == path }) { return known }
        let item = ProgramItem(id: UUID(), path: path)
        items.append(item)
        try JSONEncoder().encode(items).write(to: index, options: .atomic)
        return item
    }

    /// Deletes the program's Windows environment, including everything saved in it. The original file is kept.
    public func remove(_ item: ProgramItem) throws {
        let dir = folder(for: item)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.trashItem(at: dir, resultingItemURL: nil) }
        items.removeAll { $0.id == item.id }
        try JSONEncoder().encode(items).write(to: index, options: .atomic)
    }

    /// The program's own user folder (Downloads, Documents, Desktop), or nil before first use.
    public func userFolder(for item: ProgramItem, user: String = NSUserName()) -> URL? {
        let dir = environment(for: item).appendingPathComponent("drive_c/users/\(user)")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    public var downloads: URL { root.appendingPathComponent("Downloads") }
    public func folder(for item: ProgramItem) -> URL { root.appendingPathComponent("Apps/\(item.id.uuidString)") }
    public func environment(for item: ProgramItem) -> URL { folder(for: item).appendingPathComponent("prefix") }
    public func log(for item: ProgramItem) -> URL { folder(for: item).appendingPathComponent("last-run.log") }
}
