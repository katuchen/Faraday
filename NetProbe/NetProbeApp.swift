import SwiftUI

@main
struct NetProbeApp: App {
    @State private var model = ProbeModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.startFromLaunchArguments() }
        }
    }
}

@MainActor
@Observable
final class ProbeModel {
    private(set) var results: [ProbeResult] = []
    private(set) var isRunning = false
    private(set) var watchLines: [String] = []

    @ObservationIgnored private var watcher: Watcher?
    @ObservationIgnored private let arguments = ProcessInfo.processInfo.arguments

    private var localPort: Int? {
        arguments.firstIndex(of: "-localPort").flatMap { index in
            arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
        }
    }

    func startFromLaunchArguments() async {
        if arguments.contains("-watch") {
            startWatching()
        }
        if arguments.contains("-autorun") {
            await run()
            if !arguments.contains("-watch") {
                exit(0)
            }
        }
    }

    func run() async {
        isRunning = true
        results = await Probes.runAll(localPort: localPort)
        isRunning = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(results) {
            emit("NETPROBE_RESULTS " + String(decoding: data, as: UTF8.self))
        }
    }

    func startWatching() {
        guard watcher == nil else { return }
        watcher = Watcher { [weak self] line in
            self?.watchLines.insert(line, at: 0)
            self?.watchLines = Array(self?.watchLines.prefix(30) ?? [])
        }
        watcher?.start()
    }
}

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

struct ContentView: View {
    let model: ProbeModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(model.isRunning ? "Running…" : "Run All Probes") {
                        Task { await model.run() }
                    }
                    .disabled(model.isRunning)
                    Button("Watch Path & Open Connection") { model.startWatching() }
                }
                Section("Results") {
                    ForEach(model.results) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(result.name, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.ok ? .green : .red)
                            Text("\(result.detail) · \(result.milliseconds) ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.watchLines.isEmpty {
                    Section("Watch") {
                        ForEach(Array(model.watchLines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("NetProbe")
        }
    }
}
