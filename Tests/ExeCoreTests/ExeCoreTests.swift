import XCTest
@testable import ExeCore

final class ExeCoreTests: XCTestCase {
    /// Minimal PE32+ image with no sections.
    func pe(machine: UInt16 = 0x8664, subsystem: UInt16 = 2, clr: Bool = false) -> Data {
        var d = Data(count: 64 + 24 + 240)
        func put(_ v: UInt32, _ o: Int, _ n: Int) { for i in 0..<n { d[o + i] = UInt8((v >> (8 * UInt32(i))) & 255) } }
        put(0x5A4D, 0, 2); put(64, 0x3C, 4); put(0x4550, 64, 4)
        put(UInt32(machine), 68, 2); put(240, 84, 2); put(0x20B, 88, 2)
        put(UInt32(subsystem), 88 + 68, 2); put(16, 88 + 108, 4)
        if clr { put(0x2000, 88 + 112 + 14 * 8, 4) }
        return d
    }
    func temp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func testReadsHeaders() throws {
        let i = try PEInspector.inspect(pe(clr: true))
        XCTAssertEqual(i.architecture, .x64)
        XCTAssertTrue(i.isDotNet)
        XCTAssertEqual(Prediction.make(for: i).level, .uncertain)
    }
    func testDriverAndARMUnsupported() throws {
        XCTAssertEqual(Prediction.make(for: try PEInspector.inspect(pe(subsystem: 1))).level, .unsupported)
        XCTAssertEqual(Prediction.make(for: try PEInspector.inspect(pe(machine: 0xAA64))).level, .unsupported)
    }
    func testTruncatedInputNeverCrashes() {
        let d = pe()
        for n in 0..<d.count { _ = try? PEInspector.inspect(d.prefix(n)) }
        XCTAssertThrowsError(try PEInspector.inspect(Data("hello".utf8)))
    }
    func testRandomCorruptionNeverCrashes() {
        for _ in 0..<5000 {
            var d = pe()
            for _ in 0..<8 { d[Int.random(in: 0..<d.count)] = .random(in: 0...255) }
            _ = try? PEInspector.inspect(d)
        }
    }
    func testIsolationKeepsLinkTargets() throws {
        let fm = FileManager.default, root = try temp()
        let outside = root.appendingPathComponent("real"), prefix = root.appendingPathComponent("p")
        let user = prefix.appendingPathComponent("drive_c/users/me")
        for u in [outside, user, prefix.appendingPathComponent("dosdevices")] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        let keep = outside.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: keep)
        try fm.createSymbolicLink(atPath: user.appendingPathComponent("Documents").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try Isolation.apply(to: prefix)
        XCTAssertFalse(Isolation.isLink(user.appendingPathComponent("Documents")))
        XCTAssertFalse(Isolation.isLink(prefix.appendingPathComponent("dosdevices/z:")))
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
    }
    func testMigrationMovesOnceAndNeverOverwrites() throws {
        let base = try temp(), old = base.appendingPathComponent("old"), new = base.appendingPathComponent("new"), fm = FileManager.default
        let item = try Library(root: old).add(URL(fileURLWithPath: "/x/a.exe"))
        try Library.migrate(from: old, to: new)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertEqual(try Library(root: new).items, [item])
        try Library(root: old).add(URL(fileURLWithPath: "/x/b.exe"))
        try Library.migrate(from: old, to: new)
        XCTAssertEqual(try Library(root: new).items, [item])
    }
    func testUserFolderAppearsAfterFirstUse() throws {
        let lib = try Library(root: try temp()), item = try lib.add(URL(fileURLWithPath: "/x/a.exe"))
        XCTAssertNil(lib.userFolder(for: item, user: "me"))
        let dir = lib.environment(for: item).appendingPathComponent("drive_c/users/me")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(lib.userFolder(for: item, user: "me")?.path, dir.path)
    }
    func testLibraryPersistsAndDeduplicates() throws {
        let root = try temp(), lib = try Library(root: root)
        let a = try lib.add(URL(fileURLWithPath: "/x/a.exe"))
        XCTAssertEqual(try lib.add(URL(fileURLWithPath: "/x/a.exe")), a)
        XCTAssertEqual(try Library(root: root).items, [a])
    }
    func testBundledEngineWins() throws {
        let root = try temp(), bin = root.appendingPathComponent("wine/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        try Data().write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        XCTAssertEqual(WineEngine.locate(resources: root)?.binary.path, wine.path)
    }
    func testFindsOnlyNewlyInstalledPrograms() throws {
        let env = try temp(), fm = FileManager.default
        func touch(_ p: String) throws {
            let u = env.appendingPathComponent("drive_c/" + p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: u)
        }
        try touch("Program Files/Old/old.exe"); try touch("windows/notepad.exe")
        try Data(InstalledPrograms.scan(env).joined(separator: "\n").utf8).write(to: env.appendingPathComponent(".ready"))
        try touch("Program Files/New/app.exe"); try touch("Program Files/New/unins000.exe"); try touch("windows/new.exe")
        let found = InstalledPrograms.list(in: env)
        XCTAssertEqual(found.map(\.lastPathComponent), ["app.exe"])
        XCTAssertEqual(InstalledPrograms.relativePath(of: found[0], in: env), "Program Files/New/app.exe")
    }
    func testEngineFixIsCopiedIntoExistingEnvironment() throws {
        let root = try temp(), fm = FileManager.default
        let src = root.appendingPathComponent("wine/lib/wine/x86_64-windows/wow64cpu.dll")
        let dst = root.appendingPathComponent("env/drive_c/windows/system32/wow64cpu.dll")
        for u in [src, dst] { try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data("new".utf8).write(to: src); try Data("old".utf8).write(to: dst)
        try WineEngine(binary: root.appendingPathComponent("wine/bin/wine")).syncEngineFixes(to: root.appendingPathComponent("env"))
        XCTAssertEqual(try Data(contentsOf: dst), Data("new".utf8))
    }
    /// Minimal shortcut: header, LinkInfo with an ANSI local path.
    func lnk(_ path: String) -> Data {
        var d = Data(count: 0x4C); d[0] = 0x4C; d[0x14] = 2
        var info = Data(count: 0x1C); info[0] = UInt8(0x1C + path.utf8.count + 1); info[4] = 0x1C; info[8] = 1; info[0x10] = 0x1C
        info += Data(path.utf8) + Data([0])
        d += info
        return d
    }
    func testOnlyShortcutTargetsAreListed() throws {
        let env = try temp(), fm = FileManager.default
        func put(_ p: String, _ d: Data = Data("x".utf8)) throws {
            let u = env.appendingPathComponent("drive_c/" + p)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: u)
        }
        try Data().write(to: env.appendingPathComponent(".ready"))
        try put("Program Files/A/app.exe"); try put("Program Files/A/helper.exe"); try put("Program Files/A/unins000.exe")
        let menu = "ProgramData/Microsoft/Windows/Start Menu/Programs/A/"
        try put(menu + "My App.lnk", lnk("C:\\Program Files\\A\\app.exe"))
        try put("users/me/Desktop/My App.lnk", lnk("C:\\Program Files\\A\\app.exe"))
        try put(menu + "Uninstall.lnk", lnk("C:\\Program Files\\A\\unins000.exe"))
        try put(menu + "Escape.lnk", lnk("C:\\..\\..\\evil.exe"))
        XCTAssertEqual(WindowsApps.list(in: env).map(\.name), ["My App"])
    }
    func testShortcutParserSurvivesGarbage() {
        let d = lnk("C:\\a.exe")
        for n in 0..<d.count { _ = WindowsApps.shortcutTarget(d.prefix(n)) }
        for _ in 0..<3000 { var x = d; for _ in 0..<6 { x[Int.random(in: 0..<x.count)] = .random(in: 0...255) }; _ = WindowsApps.shortcutTarget(x) }
    }
    func testIconParserSurvivesGarbage() {
        for _ in 0..<3000 { var x = pe(); for _ in 0..<12 { x[Int.random(in: 0..<x.count)] = .random(in: 0...255) }; _ = try? PEInspector.icon(x) }
    }
    func testDotNetDetection() {
        XCTAssertEqual(Requirements.dotNetMajor(Data(#"{"runtimeOptions":{"frameworks":[{"name":"Microsoft.NETCore.App","version":"9.0.0"}]}}"#.utf8)), 9)
        XCTAssertNil(Requirements.dotNetMajor(Data(#"{"runtimeOptions":{"includedFrameworks":[{"name":"x","version":"9.0.0"}]}}"#.utf8)))
        let reg = "[Software\\\\Microsoft\\\\NET Framework Setup\\\\NDP\\\\v4\\\\Full] 1\n\"Release\"=dword:00080eb1\n\n[Other]\n"
        XCTAssertEqual(Requirements.netFrameworkRelease(reg), 528049)
        XCTAssertEqual(Requirements.netFrameworkRelease("[Other]\n\"Release\"=dword:00080eb1"), 0)
    }
    func testMonoIsNotMistakenForMicrosoftDotNet() throws {
        let env = try temp()
        try Data("[Software\\\\Microsoft\\\\NET Framework Setup\\\\NDP\\\\v4\\\\Full] 1\n\"Release\"=dword:00080eb1\n".utf8).write(to: env.appendingPathComponent("system.reg"))
        XCTAssertFalse(Requirements.isInstalled(.netFramework48, in: env))
        let dir = env.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework64/v4.0.30319")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("clr.dll"))
        XCTAssertTrue(Requirements.isInstalled(.netFramework48, in: env))
    }
    func testWrongChecksumIsRejected() throws {
        let f = try temp().appendingPathComponent("f"); try Data("x".utf8).write(to: f)
        XCTAssertFalse(try ComponentInstaller.verify(f, .init(url: f, file: "f", sha256: "00")))
        XCTAssertFalse(try ComponentInstaller.verify(f, .init(url: f, file: "f")))
    }
    func testSandboxBlocksHomeButAllowsEnvironment() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent("Library/Caches/mer-test-\(UUID().uuidString)")
        let env = base.appendingPathComponent("env \"quoted\" (x)"), app = base.appendingPathComponent("app"), other = base.appendingPathComponent("other")
        for u in [env, app, other] {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u.appendingPathComponent("f"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let args = Sandbox.arguments(environment: env, engine: URL(fileURLWithPath: "/usr/bin/x/wine"), readable: app)
        func ok(_ cmd: [String]) throws -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec"); p.arguments = args + cmd
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            return p.terminationStatus == 0
        }
        XCTAssertTrue(try ok(["/bin/cat", env.path + "/f"]))
        XCTAssertTrue(try ok(["/usr/bin/touch", env.path + "/new"]))
        XCTAssertTrue(try ok(["/bin/cat", app.path + "/f"]))
        XCTAssertFalse(try ok(["/usr/bin/touch", app.path + "/new"]))
        XCTAssertFalse(try ok(["/bin/cat", other.path + "/f"]))
        XCTAssertFalse(try ok(["/bin/ls", home.path]))
        XCTAssertFalse(try ok(["/usr/bin/touch", home.path + "/.mer-should-not-exist"]))
        // A link inside the environment must not be a way out.
        try FileManager.default.createSymbolicLink(at: env.appendingPathComponent("out"), withDestinationURL: other)
        XCTAssertFalse(try ok(["/bin/cat", env.path + "/out/f"]))
    }
    func testRealEnvironmentIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["REAL_ENV"] else { throw XCTSkip("REAL_ENV not set") }
        let env = URL(fileURLWithPath: path)
        for a in WindowsApps.list(in: env) {
            print("APP:", a.name, a.program.lastPathComponent, "needs", Requirements.needed(by: a.program), "missing", Requirements.missing(for: a.program, in: env), "icon", PEInspector.icon(a.program)?.count ?? 0)
        }
    }
    func testRealExecutableIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["REAL_EXE"] else { throw XCTSkip("REAL_EXE not set") }
        let i = try PEInspector.inspect(URL(fileURLWithPath: path))
        print("REAL:", i)
        XCTAssertFalse(i.imports.isEmpty)
    }
}
