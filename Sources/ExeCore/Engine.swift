import Foundation

public enum EngineError: LocalizedError {
    case notInstalled, rosettaMissing, setupFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "The bundled Wine engine is missing. Reinstall ExeFlow."
        case .rosettaMissing: return "Apple Rosetta is required to run Intel programs."
        case .setupFailed(let why): return "Could not prepare the Windows environment. \(why)"
        }
    }
}

/// Rosetta is part of macOS and can't be bundled, so Apple's own installer is invoked.
public enum Rosetta {
    public static let licenseURL = URL(string: "https://www.apple.com/legal/sla/")!
    /// Call only after the user has agreed to Apple's license.
    public static func install() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        p.arguments = ["--install-rosetta", "--agree-to-license"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, WineEngine.rosettaWorks() else {
            throw EngineError.setupFailed("Rosetta could not be installed. Check your internet connection.")
        }
    }
}

/// Everything above this protocol is engine-agnostic. ARM64 Wine or a VM becomes another conformance.
public protocol Engine: Sendable {
    var name: String { get }
    func checkReady() throws
    /// Blocks until the program exits; call off the main thread.
    func run(program: URL, environment: URL, log: URL) throws -> Int32
    /// Force-closes everything running in the environment. Unsaved work is lost.
    func stop(environment: URL) throws
}

public struct WineEngine: Engine {
    public let binary: URL
    public var name: String { "Wine (\(binary.path))" }
    public init(binary: URL) { self.binary = binary }

    public static func locate(fileManager fm: FileManager = .default, resources: URL? = Bundle.main.resourceURL) -> WineEngine? {
        // The bundled engine always wins; the rest help during development.
        var candidates: [String] = []
        if let resources { candidates.append(resources.appendingPathComponent("wine/bin/wine").path) }
        let home = fm.homeDirectoryForCurrentUser.path
        for dir in ["\(home)/Library/Application Support/ExeFlow/Engines", "\(home)/Applications", "/Applications"] {
            for app in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            where app.hasPrefix("Wine") && app.hasSuffix(".app") {
                candidates.append("\(dir)/\(app)/Contents/Resources/wine/bin/wine")
            }
        }
        candidates += ["/opt/homebrew/bin/wine", "/usr/local/bin/wine"]
        return candidates.first(where: fm.isExecutableFile(atPath:)).map { WineEngine(binary: URL(fileURLWithPath: $0)) }
    }

    public func checkReady() throws {
        #if arch(arm64)
        if try Self.isIntelOnly(binary), !Self.rosettaWorks() { throw EngineError.rosettaMissing }
        #endif
    }

    public static func needsRosettaInstall() -> Bool { !rosettaWorks() }

    static func isIntelOnly(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Thin 64-bit Mach-O: little-endian magic, then CPU type x86_64.
        return [UInt8](try handle.read(upToCount: 8) ?? Data()) == [0xCF, 0xFA, 0xED, 0xFE, 0x07, 0, 0, 0x01]
    }

    static func rosettaWorks() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", "/usr/bin/true"]
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    public func run(program: URL, environment: URL, log: URL) throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        // wineserver opens files for every program and keeps the sandbox it started with,
        // so the readable folder is fixed per environment rather than per launch.
        if InstalledPrograms.relativePath(of: program, in: environment) == nil {
            try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
            let folder = program.deletingLastPathComponent()
            if Sandbox.readableFolder(environment) != folder {
                try? stop(environment: environment)
                try Data(folder.path.utf8).write(to: environment.appendingPathComponent(".readable"))
            }
        }
        let session = try session(environment: environment, log: log)
        return try session.run([], folder: program.deletingLastPathComponent(), installer: program)
    }

    /// Prepares the environment (first use takes a while) and returns a way to run commands in it.
    public func session(environment: URL, log: URL) throws -> WineSession {
        try checkReady()
        let fm = FileManager.default
        try fm.createDirectory(at: environment, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        let session = WineSession(engine: self, environment: environment, log: log)
        // Marker is written last, so an interrupted setup is retried.
        let ready = environment.appendingPathComponent(".ready")
        if !fm.fileExists(atPath: ready.path) {
            let status = try session.run(["wineboot", "--init"])
            guard status == 0 else { throw EngineError.setupFailed("Setup exited with code \(status).") }
            _ = try session.run(["wineserver", "-w"])
            try Isolation.apply(to: environment)
            try Data(InstalledPrograms.scan(environment).joined(separator: "\n").utf8).write(to: ready)
        }
        try syncEngineFixes(to: environment)
        // Wine reaches its bundled .NET and HTML engines through a drive; expose only that folder.
        let share = binary.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/wine")
        try Isolation.mapDrive("y:", to: share, in: environment)
        return session
    }

    public func stop(environment: URL) throws {
        let p = Process()
        p.executableURL = binary.deletingLastPathComponent().appendingPathComponent("wineserver")
        p.arguments = ["-k"]
        p.environment = ["WINEPREFIX": environment.path, "HOME": NSHomeDirectory()]
        try p.run()
        p.waitUntilExit()
    }

    /// Environments keep their own copy of system DLLs, so engine fixes must be copied in.
    func syncEngineFixes(to environment: URL) throws {
        let source = binary.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-windows/wow64cpu.dll")
        let target = environment.appendingPathComponent("drive_c/windows/system32/wow64cpu.dll")
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path), fm.fileExists(atPath: target.path),
              !fm.contentsEqual(atPath: source.path, andPath: target.path) else { return }
        try Data(contentsOf: source).write(to: target, options: .atomic)
    }
}

public struct WineSession: Sendable {
    let engine: WineEngine
    let environment: URL
    let log: URL

    /// Runs `installer` (any .exe or .msi) if given, otherwise the Wine command in `command`.
    public func run(_ command: [String], folder: URL? = nil, installer: URL? = nil, arguments: [String] = [], overrides: String? = nil) throws -> Int32 {
        var args = command
        if let program = installer {
            let path: String
            if let inside = InstalledPrograms.relativePath(of: program, in: environment) {
                path = "C:\\" + inside.replacingOccurrences(of: "/", with: "\\")
            } else {
                try Isolation.mapDrive("d:", to: program.deletingLastPathComponent(), in: environment)
                path = "D:\\" + program.lastPathComponent
            }
            args = (program.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", path] : [path]) + arguments
        }
        let bin = engine.binary.deletingLastPathComponent()
        let p = Process()
        if args.first == "wineserver" {
            p.executableURL = bin.appendingPathComponent("wineserver")
            p.arguments = Array(args.dropFirst())
        } else {
            // The first process starts wineserver, which inherits the sandbox.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = Sandbox.arguments(environment: environment, engine: engine.binary, readable: Sandbox.readableFolder(environment)) + [engine.binary.path] + args
        }
        // Allowlist: don't hand tokens and other shell secrets to Windows programs.
        var env = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"].contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINEPREFIX"] = environment.path
        env["WINEDEBUG"] = "fixme-all"
        if let overrides { env["WINEDLLOVERRIDES"] = overrides }
        p.environment = env
        // The folder must be visible inside the environment, or Windows reports "directory name invalid".
        p.currentDirectoryURL = folder ?? environment.appendingPathComponent("drive_c")
        if !FileManager.default.fileExists(atPath: p.currentDirectoryURL!.path) { p.currentDirectoryURL = environment }
        let out = try FileHandle(forWritingTo: log)
        defer { try? out.close() }
        try out.seekToEnd()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Keeps Windows programs out of the user's files. Strong, but not a guarantee against a determined attacker.
public enum Sandbox {
    /// Apple's rule language: later rules win, but only against rules for the same operation.
    static let profile = """
    (version 1)
    (allow default)
    (deny file-read-data file-write* (subpath (param "HOME")) (subpath "/Volumes"))
    (deny appleevent-send lsopen)
    (allow file-read-data file-write* (subpath (param "ENV")))
    (allow file-read-data (subpath (param "WINE")) (subpath (param "APP")) (subpath (string-append (param "HOME") "/Library/Fonts")))
    """

    static func readableFolder(_ environment: URL) -> URL? {
        (try? String(contentsOf: environment.appendingPathComponent(".readable"), encoding: .utf8)).map { URL(fileURLWithPath: $0) }
    }

    /// `readable` is the folder of the opened file; programs can read it but not change it.
    static func arguments(environment: URL, engine: URL, readable: URL?) -> [String] {
        func real(_ u: URL) -> String { u.path.withCString { p in realpath(p, nil).map { r in defer { free(r) }; return String(cString: r) } ?? u.path } }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let wine = engine.deletingLastPathComponent().deletingLastPathComponent()
        let env = real(environment)
        return ["-D", "HOME=" + real(home), "-D", "ENV=" + env, "-D", "WINE=" + real(wine),
                "-D", "APP=" + (readable.map(real) ?? env), "-p", profile]
    }
}

/// Reduces accidental file access from inside Windows. The protection against deliberate access is `Sandbox`.
public enum Isolation {
    public static func apply(to prefix: URL) throws {
        let fm = FileManager.default
        let z = prefix.appendingPathComponent("dosdevices/z:")
        if isLink(z) { try fm.removeItem(at: z) }
        let users = prefix.appendingPathComponent("drive_c/users")
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            for item in (try? fm.contentsOfDirectory(at: user, includingPropertiesForKeys: nil)) ?? [] where isLink(item) {
                let target = try fm.destinationOfSymbolicLink(atPath: item.path)
                guard target.hasPrefix("/") else { continue }
                try fm.removeItem(at: item) // removes the link only
                try fm.createDirectory(at: item, withIntermediateDirectories: false)
            }
        }
    }

    public static func mapDrive(_ letter: String, to folder: URL, in prefix: URL) throws {
        let fm = FileManager.default
        let devices = prefix.appendingPathComponent("dosdevices")
        try fm.createDirectory(at: devices, withIntermediateDirectories: true)
        let link = devices.appendingPathComponent(letter)
        if isLink(link) { try fm.removeItem(at: link) }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: folder.path)
    }

    static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

/// Finds programs an installer added, by comparing against the list saved at setup.
public enum InstalledPrograms {
    public static func list(in environment: URL) -> [URL] {
        guard let saved = try? String(contentsOf: environment.appendingPathComponent(".ready"), encoding: .utf8) else { return [] }
        let baseline = Set(saved.split(separator: "\n").map(String.init))
        let root = environment.appendingPathComponent("drive_c")
        return scan(environment).filter { !baseline.contains($0) }.map { root.appendingPathComponent($0) }
    }

    /// Paths of .exe files relative to drive_c, skipping Windows itself, temp files and uninstallers.
    static func scan(_ environment: URL) -> [String] {
        let root = environment.appendingPathComponent("drive_c")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var found: [String] = []
        while let path = walker.nextObject() as? String {
            let lower = path.lowercased()
            if lower == "windows" || lower.hasSuffix("/appdata/local/temp") { walker.skipDescendants(); continue }
            let name = (lower as NSString).lastPathComponent
            if name.hasSuffix(".exe"), !lower.contains("/appdata/local/temp/"), !name.hasPrefix("unins") { found.append(path) }
        }
        return found.sorted()
    }

    static func relativePath(of program: URL, in environment: URL) -> String? {
        let root = environment.appendingPathComponent("drive_c").resolvingSymlinksInPath().path + "/"
        let path = program.resolvingSymlinksInPath().path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
    }
}
