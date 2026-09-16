import Foundation
import Network
import SystemConfiguration

@MainActor
final class Watcher {
    private let report: @MainActor (String) -> Void
    private let swiftMonitor = NWPathMonitor()
    private let cMonitor = nw_path_monitor_create()
    private var reachability: SCNetworkReachability?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var pingTimer: Timer?

    init(report: @escaping @MainActor (String) -> Void) {
        self.report = report
    }

    func start() {
        swiftMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.line("NETPROBE_PATH swift \(path.status)") }
        }
        swiftMonitor.start(queue: .main)

        nw_path_monitor_set_update_handler(cMonitor) { [weak self] path in
            let status = Probes.describe(nw_path_get_status(path))
            Task { @MainActor in self?.line("NETPROBE_PATH c \(status)") }
        }
        nw_path_monitor_set_queue(cMonitor, .main)
        nw_path_monitor_start(cMonitor)

        if let target = SCNetworkReachabilityCreateWithName(nil, "www.apple.com") {
            SCNetworkReachabilitySetCallback(target, { _, flags, _ in
                emit("NETPROBE_PATH scnetworkreachability flags 0x\(String(flags.rawValue, radix: 16))")
            }, nil)
            SCNetworkReachabilitySetDispatchQueue(target, .main)
            reachability = target
        }

        openSocket()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ping() }
        }
    }

    private func openSocket() {
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: URL(string: "wss://ws.postman-echo.com/raw")!)
        socket.resume()
        self.session = session
        self.socket = socket
        line("NETPROBE_WS opening")
    }

    private func ping() {
        guard let socket else { return }
        socket.sendPing { [weak self] error in
            let state = error.map { "dead: \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "alive"
            Task { @MainActor in self?.line("NETPROBE_WS \(state)") }
        }
    }

    private func line(_ text: String) {
        emit(text)
        report(text)
    }
}
