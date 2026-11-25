import Foundation

public enum Requirement: Hashable, Sendable {
    case netFramework48
    case dotNet(major: Int, x86: Bool)

    public var title: String {
        switch self {
        case .netFramework48: return "Microsoft .NET Framework 4.8"
        case .dotNet(let major, let x86): return "Microsoft .NET \(major) Desktop Runtime\(x86 ? " (32-bit)" : "")"
        }
    }
    public var licenseURL: URL {
        switch self {
        case .netFramework48: return URL(string: "https://dotnet.microsoft.com/en-us/dotnet_library_license.htm")!
        case .dotNet: return URL(string: "https://dotnet.microsoft.com/en-us/dotnet_library_license.htm")!
        }
    }
    public var sizeNote: String {
        switch self {
        case .netFramework48: return "About 170 MB to download. Takes around 5 minutes."
        case .dotNet: return "About 60 MB to download."
        }
    }
}

public enum Requirements {
    /// What `program` needs that its environment doesn't have yet.
    public static func missing(for program: URL, in environment: URL) -> [Requirement] {
        needed(by: program).filter { !isInstalled($0, in: environment) }
    }

    static func needed(by program: URL) -> [Requirement] {
        guard program.pathExtension.lowercased() == "exe", let info = try? PEInspector.inspect(program) else { return [] }
        if info.isDotNet, frameworkMajor(program) == 4 { return [.netFramework48] }
        let config = program.deletingPathExtension().appendingPathExtension("runtimeconfig.json")
        if let data = try? Data(contentsOf: config), let major = dotNetMajor(data) {
            return [.dotNet(major: major, x86: info.architecture == .x86)]
        }
        return []
    }

    /// .NET Framework major version; 2 and 3 run on the bundled Mono.
    static func frameworkMajor(_ program: URL) -> Int {
        let config = URL(fileURLWithPath: program.path + ".config")
        if let text = try? String(contentsOf: config, encoding: .utf8), text.contains("supportedRuntime") {
            return text.contains("version=\"v4") ? 4 : 2
        }
        guard let data = try? Data(contentsOf: program, options: .mappedIfSafe) else { return 0 }
        if data.range(of: Data(".NETFramework,Version=v4".utf8)) != nil { return 4 }
        return data.range(of: Data("v4.0.30319".utf8)) != nil ? 4 : 2
    }

    static func dotNetMajor(_ json: Data) -> Int? {
        guard let top = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let options = top["runtimeOptions"] as? [String: Any],
              options["includedFrameworks"] == nil else { return nil } // self-contained
        let list = (options["frameworks"] as? [[String: Any]]) ?? [(options["framework"] as? [String: Any]) ?? [:]]
        return list.compactMap { ($0["version"] as? String)?.split(separator: ".").first.flatMap { Int($0) } }.max()
    }

    static func isInstalled(_ requirement: Requirement, in environment: URL) -> Bool {
        switch requirement {
        case .netFramework48:
            // Wine's Mono claims to be .NET 4.8 in the registry; only Microsoft's version has clr.dll.
            let clr = environment.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll")
            guard FileManager.default.fileExists(atPath: clr.path),
                  let data = try? Data(contentsOf: environment.appendingPathComponent("system.reg")) else { return false }
            return netFrameworkRelease(String(decoding: data, as: UTF8.self)) >= 528040
        case .dotNet(let major, let x86):
            let base = x86 ? "Program Files (x86)" : "Program Files"
            let dir = environment.appendingPathComponent("drive_c/\(base)/dotnet/shared/Microsoft.WindowsDesktop.App")
            return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasPrefix("\(major).") }
        }
    }

    static func netFrameworkRelease(_ registry: String) -> Int {
        guard let key = registry.range(of: "[Software\\\\Microsoft\\\\NET Framework Setup\\\\NDP\\\\v4\\\\Full]") else { return 0 }
        let section = registry[key.upperBound...].components(separatedBy: "\n[").first ?? ""
        guard let value = section.range(of: "\"Release\"=dword:") else { return 0 }
        return Int(section[value.upperBound...].prefix(8), radix: 16) ?? 0
    }
}
