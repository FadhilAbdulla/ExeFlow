// Developer tool.
//   exerun <wine-resources> <environment> <log> <program>
//   exerun --setup <wine-resources> <environment> <log> <program> <downloads>   (accepts component licenses!)
import Foundation
import ExeCore

var a = Array(CommandLine.arguments.dropFirst())
let setup = a.first == "--setup"
if setup { a.removeFirst() }
guard a.count == (setup ? 5 : 4), let engine = WineEngine.locate(resources: URL(fileURLWithPath: a[0])) else {
    print("usage: exerun [--setup] <wine-resources> <environment> <log> <program> [downloads]"); exit(64)
}
setvbuf(stdout, nil, _IONBF, 0)
let env = URL(fileURLWithPath: a[1]), log = URL(fileURLWithPath: a[2]), program = URL(fileURLWithPath: a[3])
do {
    if setup {
        let installer = ComponentInstaller(engine: engine, downloads: URL(fileURLWithPath: a[4]))
        for need in Requirements.missing(for: program, in: env) {
            print("needs:", need.title)
            try await installer.install(need, environment: env, log: log) { if !$0.hasSuffix("%") { print(" ", $0) } }
        }
        print("still missing:", Requirements.missing(for: program, in: env))
    } else {
        print("exit:", try engine.run(program: program, name: program.deletingPathExtension().lastPathComponent, environment: env, log: log))
    }
} catch { print("error:", error.localizedDescription); exit(1) }
