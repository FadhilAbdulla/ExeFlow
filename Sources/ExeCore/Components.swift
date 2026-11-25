import Foundation
import CryptoKit

/// Downloads Microsoft components from Microsoft and installs them into one environment.
/// Call `install` only after the user agreed to the license.
public struct ComponentInstaller: Sendable {
    public let engine: WineEngine
    public let downloads: URL
    public init(engine: WineEngine, downloads: URL) { self.engine = engine; self.downloads = downloads }

    struct Package { var url: URL; var file: String; var sha256: String?; var sha512: String? }

    static let net40 = Package(
        url: URL(string: "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe")!,
        file: "dotNetFx40_Full_x86_x64.exe", sha256: "65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f")
    static let net48 = Package(
        url: URL(string: "https://download.microsoft.com/download/f/3/a/f3a6af84-da23-40a5-8d1c-49cc10c8e76f/NDP48-x86-x64-AllOS-ENU.exe")!,
        file: "NDP48-x86-x64-AllOS-ENU.exe", sha256: "0a3a390c47e639d0f7fc65b21195fee6b7f65b066f80f70c60fab191d14b7e40")

    public func install(_ requirement: Requirement, environment: URL, log: URL, status: @escaping @Sendable (String) -> Void) async throws {
        switch requirement {
        case .netFramework48:
            let first = try await fetch(Self.net40, label: "Downloading .NET (1 of 2)", status)
            let second = try await fetch(Self.net48, label: "Downloading .NET (2 of 2)", status)
            try await offMain { try installFramework(first, second, environment, log, status) }
        case .dotNet(let major, let x86):
            status("Finding the latest .NET \(major)…")
            let file = try await fetch(try await runtimePackage(major: major, x86: x86), label: "Downloading .NET \(major)", status)
            status("Installing .NET \(major)…")
            try await offMain {
                let session = try engine.session(environment: environment, log: log)
                try withCopy(of: file, in: environment) {
                    try expectSuccess(try session.run([], folder: $0.deletingLastPathComponent(), installer: $0, arguments: ["/install", "/quiet", "/norestart"]), ".NET \(major)")
                }
            }
        }
        try? engine.stop(environment: environment) // flushes the registry and ends leftover services
        guard Requirements.isInstalled(requirement, in: environment) else {
            throw EngineError.setupFailed("\(requirement.title) did not install correctly. See the log.")
        }
    }

    private func installFramework(_ net40: URL, _ net48: URL, _ environment: URL, _ log: URL, _ status: (String) -> Void) throws {
        let session = try engine.session(environment: environment, log: log)
        try engine.stop(environment: environment)
        status("Preparing…")
        // Wine's Mono registers itself as .NET 4, which makes Microsoft's installer refuse to run.
        for key in ["v3.5", "v4"] {
            for view in ["/reg:64", "/reg:32"] {
                _ = try session.run(["reg", "delete", "HKLM\\Software\\Microsoft\\NET Framework Setup\\NDP\\\(key)", "/f", view])
            }
        }
        for dir in ["system32", "syswow64"] {
            try? FileManager.default.removeItem(at: environment.appendingPathComponent("drive_c/windows/\(dir)/mscoree.dll"))
        }
        _ = try session.run(["winecfg", "/v", "win7"])
        status("Installing .NET (1 of 2)…")
        try withCopy(of: net40, in: environment) {
            try expectSuccess(try session.run([], folder: $0.deletingLastPathComponent(), installer: $0, arguments: ["/q", "/norestart"], overrides: "fusion=b;mscoree="), ".NET 4.0")
        }
        try engine.stop(environment: environment)
        _ = try session.run(["reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", "*mscoree", "/t", "REG_SZ", "/d", "native", "/f"])
        _ = try session.run(["winecfg", "/v", "win7"])
        status("Installing .NET (2 of 2)… This can take a few minutes.")
        try withCopy(of: net48, in: environment) {
            try expectSuccess(try session.run([], folder: $0.deletingLastPathComponent(), installer: $0, arguments: ["/q", "/norestart"], overrides: "fusion=b"), ".NET 4.8")
        }
        try engine.stop(environment: environment)
        _ = try session.run(["winecfg", "/v", "win10"])
    }

    /// The sandbox hides the downloads folder, so installers run from a temporary copy inside the environment.
    private func withCopy(of file: URL, in environment: URL, _ work: (URL) throws -> Void) throws {
        let dir = environment.appendingPathComponent("drive_c/mer-setup")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: file, to: copy)
        try work(copy)
    }

    private func expectSuccess(_ code: Int32, _ what: String) throws {
        // 3010 and 1641 mean "restart needed"; only the low byte survives as a Unix exit code.
        guard [0, 3010 & 0xFF, 1641 & 0xFF].contains(code) else {
            throw EngineError.setupFailed("\(what) setup stopped with code \(code).")
        }
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            Thread.detachNewThread { done.resume(with: Result { try work() }) }
        }
    }

    func runtimePackage(major: Int, x86: Bool) async throws -> Package {
        let url = URL(string: "https://builds.dotnet.microsoft.com/dotnet/release-metadata/\(major).0/releases.json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try Self.parseRelease(data, x86: x86)
    }

    static func parseRelease(_ data: Data, x86: Bool) throws -> Package {
        struct Meta: Decodable {
            struct Release: Decodable { var windowsdesktop: Desktop? }
            struct Desktop: Decodable { var files: [File] }
            struct File: Decodable { var name: String; var url: URL; var hash: String }
            var releases: [Release]
        }
        let want = "windowsdesktop-runtime-win-\(x86 ? "x86" : "x64").exe"
        for release in try JSONDecoder().decode(Meta.self, from: data).releases {
            if let f = release.windowsdesktop?.files.first(where: { $0.name == want }), f.url.scheme == "https",
               f.url.host == "builds.dotnet.microsoft.com" {
                return Package(url: f.url, file: f.url.lastPathComponent, sha256: nil, sha512: f.hash.lowercased())
            }
        }
        throw EngineError.setupFailed("Microsoft does not list a download for this .NET version.")
    }

    func fetch(_ package: Package, label: String, _ status: @escaping @Sendable (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let target = downloads.appendingPathComponent(package.file)
        if fm.fileExists(atPath: target.path), (try? Self.verify(target, package)) == true { return target }
        var lastError: Error = EngineError.setupFailed("Download failed.")
        for _ in 0..<3 {
            do {
                status("\(label)…")
                let temp = try await Download.run(package.url) { status("\(label)… \(Int($0 * 100))%") }
                defer { try? fm.removeItem(at: temp) }
                guard try Self.verify(temp, package) else {
                    throw EngineError.setupFailed("The download did not match Microsoft's checksum, so it was discarded.")
                }
                try? fm.removeItem(at: target)
                try fm.moveItem(at: temp, to: target)
                return target
            } catch { lastError = error }
        }
        throw lastError
    }

    static func verify(_ file: URL, _ package: Package) throws -> Bool {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }
        if let want = package.sha256 { return hex(SHA256.hash(data: data)) == want }
        if let want = package.sha512 { return hex(SHA512.hash(data: data)) == want }
        return false
    }
}

private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var done: CheckedContinuation<URL, Error>?
    private init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    static func run(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = Download(progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60 // a stalled connection fails instead of hanging
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation {
            delegate.done = $0
            session.downloadTask(with: url).resume()
        }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
    private func finish(_ result: Result<URL, Error>) {
        done?.resume(with: result)
        done = nil
    }
}
