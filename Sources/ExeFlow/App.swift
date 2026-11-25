import SwiftUI
import UniformTypeIdentifiers
import ExeCore

/// One row in the sidebar: a file the user opened, or a program that file installed.
struct Entry: Identifiable, Hashable {
    var item: ProgramItem
    var program: URL
    var name: String
    var isSource: Bool // the opened file itself
    var id: String { program.path }
    static func == (a: Entry, b: Entry) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var entries: [Entry] = []
    @Published var selection: String?
    @Published var running: Set<String> = [] // entry ids: programs sharing an environment run independently
    @Published var status: [UUID: String] = [:] // setup progress
    @Published var message: String?
    @Published var setup: Setup?
    @Published var removing: ProgramItem?
    @Published var showHidden = false { didSet { refresh() } }
    private var hidden = Set(UserDefaults.standard.stringArray(forKey: "hidden") ?? [])
    private var icons: [String: NSImage] = [:]
    private var library: Library?

    struct Setup: Identifiable {
        var entry: Entry
        var requirement: Requirement
        var id: String { entry.id }
    }

    init() {
        do {
            try Library.migrate(from: Library.defaultRoot.deletingLastPathComponent().appendingPathComponent("MacExeRunner"), to: Library.defaultRoot)
            library = try Library(root: Library.defaultRoot)
        } catch {
            message = "Could not open the library: \(error.localizedDescription)"
        }
        refresh()
        selection = entries.first?.id
    }

    var selected: Entry? { entries.first { $0.id == selection } }
    func isRunning(_ e: Entry) -> Bool { running.contains(e.id) }
    func isBusy(_ e: Entry) -> Bool { isRunning(e) || status[e.item.id] != nil }
    /// Others that Stop would close too, because they share the environment.
    func alsoRunning(_ e: Entry) -> [Entry] { entries.filter { $0.item.id == e.item.id && $0.id != e.id && isRunning($0) } }
    func isHidden(_ e: Entry) -> Bool { hidden.contains(e.id) }

    func refresh() {
        guard let library else { return }
        entries = library.items.flatMap { item -> [Entry] in
            let apps = WindowsApps.list(in: library.environment(for: item))
            if apps.isEmpty { return [Entry(item: item, program: item.url, name: item.name, isSource: true)] }
            let all = apps.map { Entry(item: item, program: $0.program, name: $0.name, isSource: false) }
            let shown = all.filter { showHidden || !hidden.contains($0.id) }
            return shown.isEmpty ? Array(all.prefix(1)) : shown // never leave a program unreachable
        }
        if selected == nil { selection = entries.first?.id }
    }

    func toggleHidden(_ e: Entry) {
        if hidden.remove(e.id) == nil { hidden.insert(e.id) }
        UserDefaults.standard.set(Array(hidden), forKey: "hidden")
        refresh()
    }

    func icon(_ e: Entry) -> NSImage {
        if let known = icons[e.id] { return known }
        let image = PEInspector.icon(e.program).flatMap(NSImage.init(data:)) ?? NSWorkspace.shared.icon(for: .exe)
        icons[e.id] = image
        return image
    }

    func missing(_ e: Entry) -> [Requirement] {
        library.map { Requirements.missing(for: e.program, in: $0.environment(for: e.item)) } ?? []
    }

    /// Opening a file only adds and inspects it. Running always needs an explicit click.
    func open(_ urls: [URL]) {
        guard let library else { return }
        for url in urls {
            guard ["exe", "msi"].contains(url.pathExtension.lowercased()) else {
                message = "\(url.lastPathComponent) is not an .exe or .msi file."
                continue
            }
            do {
                if url.pathExtension.lowercased() == "exe" { _ = try PEInspector.inspect(url) }
                let item = try library.add(url)
                refresh()
                selection = entries.first { $0.item.id == item.id }?.id
            } catch { message = "\(url.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    /// The one button: asks to set up whatever is missing, then launches.
    func start(_ e: Entry, skipCheck: Bool = false) {
        guard !isBusy(e) else { return }
        #if arch(arm64)
        if WineEngine.needsRosettaInstall() { rosettaFor = e; return }
        #endif
        if !skipCheck, let first = missing(e).first {
            if let other = alsoRunning(e).first { message = "Close \(other.name) first. Setup needs to restart its Windows environment."; return }
            setup = Setup(entry: e, requirement: first)
            return
        }
        launch(e, program: e.program)
    }

    @Published var rosettaFor: Entry?

    func installRosetta(_ e: Entry) {
        status[e.item.id] = "Installing Apple Rosetta…"
        Task {
            do { try await Task.detached { try Rosetta.install() }.value; status[e.item.id] = nil; start(e) } catch {
                status[e.item.id] = nil
                message = error.localizedDescription
            }
        }
    }

    func install(_ s: Setup) {
        guard let library, let engine = WineEngine.locate() else { message = EngineError.notInstalled.localizedDescription; return }
        let id = s.entry.item.id
        status[id] = "Preparing…"
        let installer = ComponentInstaller(engine: engine, downloads: library.downloads)
        let environment = library.environment(for: s.entry.item), log = library.log(for: s.entry.item)
        Task {
            do {
                try await installer.install(s.requirement, environment: environment, log: log) { text in
                    Task { @MainActor in if AppModel.shared.status[id] != nil { AppModel.shared.status[id] = text } }
                }
                status[id] = nil
                start(s.entry) // asks for the next missing component, if any, otherwise opens
            } catch {
                status[id] = nil
                message = error.localizedDescription
            }
        }
    }

    func launch(_ e: Entry, program: URL) {
        guard let library else { return }
        guard let engine = WineEngine.locate() else { message = EngineError.notInstalled.localizedDescription; return }
        let item = e.item, name = e.name, environment = library.environment(for: item), log = library.log(for: item)
        let hadApps = !WindowsApps.list(in: environment).isEmpty
        running.insert(e.id)
        Task {
            do {
                // A dedicated thread: programs may run for hours, so don't tie up a shared worker.
                let code: Int32 = try await withCheckedThrowingContinuation { done in
                    Thread.detachNewThread {
                        done.resume(with: Result { try engine.run(program: program, name: name, environment: environment, log: log) })
                    }
                }
                if code != 0, !stopped.contains(e.id) { message = explain(e, code, log) }
            } catch { message = error.localizedDescription }
            stopped.remove(e.id)
            running.remove(e.id)
            refresh()
            if !hadApps, let app = entries.first(where: { $0.item.id == item.id && !$0.isSource }) { selection = app.id }
        }
    }

    private var stopped: Set<String> = []

    private func explain(_ e: Entry, _ code: Int32, _ log: URL) -> String {
        let text = (try? String(decoding: Data(contentsOf: log), as: UTF8.self)) ?? ""
        if text.contains("Mono is not installed") || text.contains("Could not load file or assembly") {
            return "\(e.name) needs a .NET component that isn't available."
        }
        if text.contains("not found") && text.contains("import_dll") { return "\(e.name) needs a Windows component that isn't available. See the log for its name." }
        return "\(e.name) closed unexpectedly (code \(code)). The log may say why."
    }

    func stop(_ e: Entry) {
        guard let library, let engine = WineEngine.locate() else { return }
        let environment = library.environment(for: e.item)
        for other in [e] + alsoRunning(e) { stopped.insert(other.id) }
        Task.detached { try? engine.stop(environment: environment) }
    }

    func remove(_ item: ProgramItem) {
        guard let library else { return }
        let environment = library.environment(for: item)
        do {
            if FileManager.default.fileExists(atPath: environment.path) { try? WineEngine.locate()?.stop(environment: environment) }
            try library.remove(item)
        } catch { message = error.localizedDescription }
        refresh()
    }

    /// Programs can't reach the Mac's folders, so this is where their files are saved, and where to put files for them.
    func showFiles(_ e: Entry) {
        guard let dir = library?.userFolder(for: e.item) else { message = "\(e.name) hasn't saved any files yet. Open it first."; return }
        let target = dir.appendingPathComponent("Downloads")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: target.path) ? target : dir)
    }

    func showLog(_ e: Entry) {
        guard let log = library?.log(for: e.item), FileManager.default.fileExists(atPath: log.path) else {
            message = "There is no log yet."
            return
        }
        NSWorkspace.shared.open(log)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.open(urls) }
    }
}

@main
struct ExeFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("ExeFlow", id: "main") {
            ContentView(model: .shared).frame(minWidth: 640, minHeight: 400)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var importing = false

    private func shown<T>(_ path: ReferenceWritableKeyPath<AppModel, T?>) -> Binding<Bool> {
        Binding(get: { model[keyPath: path] != nil }, set: { if !$0 { model[keyPath: path] = nil } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.entries) { e in
                    HStack {
                        Image(nsImage: model.icon(e)).resizable().frame(width: 24, height: 24)
                        Text(e.name).lineLimit(1)
                        Spacer()
                        if model.isRunning(e) { Circle().fill(.green).frame(width: 8, height: 8).help("Running") }
                        else if model.status[e.item.id] != nil, model.selection == e.id { ProgressView().controlSize(.small) }
                    }
                    .tag(e.id)
                    .opacity(model.isHidden(e) ? 0.5 : 1)
                    .contextMenu {
                        if !e.isSource { Button(model.isHidden(e) ? "Unhide" : "Hide") { model.toggleHidden(e) } }
                        Button("Show Saved Files") { model.showFiles(e) }
                        Button("Show Log") { model.showLog(e) }
                        Button("Remove…", role: .destructive) { model.removing = e.item }
                    }
                }
            }
            .frame(minWidth: 190)
            .toolbar {
                Button("Open File", systemImage: "plus") { importing = true }
                Toggle("Show Hidden", systemImage: "eye", isOn: $model.showHidden)
            }
        } detail: {
            if let e = model.selected { DetailView(model: model, entry: e) } else {
                ContentUnavailableView {
                    Label("Open a Windows program", systemImage: "square.and.arrow.down")
                } description: { Text("Drop an .exe or .msi file here.") } actions: {
                    Button("Choose File…") { importing = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.open(urls); return true }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: ["exe", "msi"].compactMap { UTType(filenameExtension: $0) },
                      allowsMultipleSelection: true) { if case .success(let urls) = $0 { model.open(urls) } }
        .alert("ExeFlow", isPresented: shown(\.message)) { Button("OK") {} } message: { Text(model.message ?? "") }
        .alert("Install Apple Rosetta?", isPresented: shown(\.rosettaFor), presenting: model.rosettaFor) { e in
            Button("Agree and Install") { model.installRosetta(e) }
            Button("Read License") { NSWorkspace.shared.open(Rosetta.licenseURL) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Windows programs need this free Apple component. Installing it means you agree to Apple's software license.") }
        .alert("Remove this program?", isPresented: shown(\.removing), presenting: model.removing) { item in
            Button("Move to Trash", role: .destructive) { model.remove(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in Text("Everything installed by \(item.url.lastPathComponent), including its saved data, moves to the Trash. The original file stays.") }
        .sheet(item: $model.setup) { SetupView(model: model, setup: $0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    let entry: Entry

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: model.icon(entry)).resizable().frame(width: 96, height: 96)
            Text(entry.name).font(.title2.bold()).multilineTextAlignment(.center)
            if let text = model.status[entry.item.id] {
                ProgressView()
                Text(text).foregroundStyle(.secondary)
            } else if model.isRunning(entry) {
                Text("Running").foregroundStyle(.secondary)
                Button("Stop", role: .destructive) { model.stop(entry) }
                Text(model.alsoRunning(entry).isEmpty ? "Stop closes it immediately. Unsaved work is lost." : "Stop also closes \(model.alsoRunning(entry).map(\.name).joined(separator: ", ")). Unsaved work is lost.").font(.caption).foregroundStyle(.secondary)
            } else if !FileManager.default.fileExists(atPath: entry.program.path) {
                Text("The file was moved or deleted.").foregroundStyle(.red)
            } else {
                let missing = model.missing(entry), unsupported = unsupportedReason
                if let unsupported { Label(unsupported, systemImage: "xmark.octagon").foregroundStyle(.red) } else {
                    ForEach(missing, id: \.self) { Label("Needs \($0.title)", systemImage: "arrow.down.circle").foregroundStyle(.orange) }
                    Button(missing.isEmpty ? (isInstaller ? "Install" : "Open") : "Set Up and Open") { model.start(entry) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    ForEach(graphicsNotes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                    Text("Programs are kept out of your personal files, but only open ones you trust.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Show Saved Files", systemImage: "folder") { model.showFiles(entry) }.buttonStyle(.borderless).padding(.bottom, 10)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var graphicsNotes: [String] {
        guard let info = try? PEInspector.inspect(entry.program) else { return [] }
        return Prediction.make(for: info).notes.filter { $0.contains("Direct3D") }
    }
    private var isInstaller: Bool { entry.isSource && PEInspector.looksLikeInstaller(entry.program) }
    private var unsupportedReason: String? {
        guard let info = try? PEInspector.inspect(entry.program) else { return nil }
        let p = Prediction.make(for: info)
        return p.level == .unsupported ? p.notes.first : nil
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    let setup: AppModel.Setup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(setup.entry.name) needs \(setup.requirement.title)").font(.headline)
            Text("ExeFlow can download it from Microsoft and install it for you. \(setup.requirement.sizeNote)")
            Text("It is Microsoft software with its own license, which is written for Windows users. Read it before agreeing.")
                .foregroundStyle(.secondary)
            Link("Read Microsoft's license", destination: setup.requirement.licenseURL)
            HStack {
                Button("Try Without It") { dismiss(); model.start(setup.entry, skipCheck: true) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Agree and Install") { dismiss(); model.install(setup) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
