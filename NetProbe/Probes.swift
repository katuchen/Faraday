import Foundation
import Network
import SystemConfiguration
import WebKit

struct ProbeResult: Codable, Sendable, Identifiable, Equatable {
    let name: String
    let ok: Bool
    let detail: String
    let milliseconds: Int

    var id: String { name }
}

struct Outcome: Sendable {
    let ok: Bool
    let detail: String

    static func failure(_ error: any Error) -> Outcome {
        let error = error as NSError
        return Outcome(ok: false, detail: "\(error.domain) \(error.code): \(error.localizedDescription)")
    }
}

final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

func awaitCallback(timeout: Double, _ start: (Once<Outcome>) -> Void) async -> Outcome {
    await withCheckedContinuation { continuation in
        let once = Once(continuation)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            once.resume(Outcome(ok: false, detail: "timed out after \(Int(timeout)) s"))
        }
        start(once)
    }
}

enum Probes {
    static let timeout = 6.0
    static let httpsURL = URL(string: "https://www.apple.com/library/test/success.html")!

    @MainActor
    static func runAll(localPort: Int?) async -> [ProbeResult] {
        var probes: [(String, () async -> Outcome)] = [
            ("urlsession-https", urlSession),
            ("urlsession-waitsForConnectivity", urlSessionWaitingForConnectivity),
            ("urlsession-http3", http3),
            ("urlsession-websocket", webSocket),
            ("getaddrinfo", { await resolve("www.apple.com") }),
            ("getaddrinfo-localhost", { await resolve("localhost") }),
            ("nwconnection-tcp-1.1.1.1", tcpWithoutDNS),
            ("nwconnection-udp-dns-1.1.1.1", udpDNSQuery),
            ("wkwebview", { await WebProbe().load(URL(string: "https://example.com/")!) }),
            ("nwpathmonitor-swift", pathMonitorSwift),
            ("nw_path_monitor-c", pathMonitorC),
            ("scnetworkreachability", reachability),
        ]
        if let localPort {
            probes.append(("localhost-\(localPort)", { await localhost(port: localPort) }))
        }

        var results: [ProbeResult] = []
        for (name, probe) in probes {
            let start = ContinuousClock.now
            let outcome = await probe()
            let elapsed = start.duration(to: .now).components
            let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            emit("NETPROBE_PROBE \(name) \(outcome.ok ? "ok" : "fail") \(milliseconds)ms \(outcome.detail)")
            results.append(ProbeResult(name: name, ok: outcome.ok, detail: outcome.detail, milliseconds: milliseconds))
        }
        return results
    }

    // MARK: URLSession

    static func urlSession() async -> Outcome {
        await get(httpsURL, configuration: .ephemeral)
    }

    static func urlSessionWaitingForConnectivity() async -> Outcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = timeout
        return await get(httpsURL, configuration: configuration)
    }

    static func localhost(port: Int) async -> Outcome {
        await get(URL(string: "http://127.0.0.1:\(port)/")!, configuration: .ephemeral, acceptAnyStatus: true)
    }

    static func get(_ url: URL, configuration: URLSessionConfiguration, acceptAnyStatus: Bool = false) async -> Outcome {
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Outcome(ok: acceptAnyStatus || status == 200, detail: "HTTP \(status)")
        } catch {
            return .failure(error)
        }
    }

    final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var name: String?

        var protocolName: String? {
            lock.withLock { name }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.withLock { name = metrics.transactionMetrics.last?.networkProtocolName }
        }
    }

    static func http3() async -> Outcome {
        var request = URLRequest(url: URL(string: "https://cloudflare-quic.com/")!, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.assumesHTTP3Capable = true
        let collector = MetricsCollector()
        let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: request)
            try? await Task.sleep(for: .milliseconds(100))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Outcome(ok: status == 200, detail: "HTTP \(status) via \(collector.protocolName ?? "unknown protocol")")
        } catch {
            return .failure(error)
        }
    }

    static func webSocket() async -> Outcome {
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "wss://ws.postman-echo.com/raw")!)
        let outcome = await awaitCallback(timeout: timeout) { once in
            task.resume()
            task.send(.string("faraday")) { error in
                if let error {
                    once.resume(.failure(error))
                    return
                }
                task.receive { result in
                    switch result {
                    case .success: once.resume(Outcome(ok: true, detail: "echo received"))
                    case .failure(let error): once.resume(.failure(error))
                    }
                }
            }
        }
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        return outcome
    }

    // MARK: Lower level

    static func resolve(_ host: String) async -> Outcome {
        await awaitCallback(timeout: timeout) { once in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(host, "443", &hints, &result)
                if let result {
                    freeaddrinfo(result)
                }
                once.resume(status == 0
                    ? Outcome(ok: true, detail: "resolved \(host)")
                    : Outcome(ok: false, detail: "getaddrinfo \(status): \(String(cString: gai_strerror(status)))"))
            }
        }
    }

    static func tcpWithoutDNS() async -> Outcome {
        let request = Data("GET / HTTP/1.1\r\nHost: one.one.one.one\r\nConnection: close\r\n\r\n".utf8)
        let connection = NWConnection(host: "1.1.1.1", port: 80, using: .tcp)
        let outcome = await awaitCallback(timeout: timeout) { once in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error {
                            once.resume(Outcome(ok: false, detail: "send: \(error)"))
                        }
                    })
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, error in
                        if let data, !data.isEmpty {
                            once.resume(Outcome(ok: true, detail: "\(data.count)-byte reply"))
                        } else {
                            once.resume(Outcome(ok: false, detail: "receive: \(error.map { "\($0)" } ?? "no data")"))
                        }
                    }
                case .failed(let error): once.resume(Outcome(ok: false, detail: "failed: \(error)"))
                case .waiting(let error): once.resume(Outcome(ok: false, detail: "waiting: \(error)"))
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "probe.tcp"))
        }
        connection.cancel()
        return outcome
    }

    static func udpDNSQuery() async -> Outcome {
        let query = Data([0x53, 0x54, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            + Data([5]) + Data("apple".utf8) + Data([3]) + Data("com".utf8) + Data([0, 0x00, 0x01, 0x00, 0x01])
        let connection = NWConnection(host: "1.1.1.1", port: 53, using: .udp)
        let outcome = await awaitCallback(timeout: timeout) { once in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: query, completion: .contentProcessed { error in
                        if let error {
                            once.resume(Outcome(ok: false, detail: "send: \(error)"))
                        }
                    })
                    connection.receiveMessage { data, _, _, error in
                        if let data, data.count > 12 {
                            once.resume(Outcome(ok: true, detail: "\(data.count)-byte reply"))
                        } else {
                            once.resume(Outcome(ok: false, detail: "receive: \(error.map { "\($0)" } ?? "no data")"))
                        }
                    }
                case .failed(let error): once.resume(Outcome(ok: false, detail: "failed: \(error)"))
                case .waiting(let error): once.resume(Outcome(ok: false, detail: "waiting: \(error)"))
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "probe.udp"))
        }
        connection.cancel()
        return outcome
    }

    // MARK: Reachability APIs (these report path state; they don't send traffic)

    static func pathMonitorSwift() async -> Outcome {
        let monitor = NWPathMonitor()
        let outcome = await awaitCallback(timeout: 3) { once in
            monitor.pathUpdateHandler = { path in
                once.resume(Outcome(ok: path.status == .satisfied, detail: "status \(path.status)"))
            }
            monitor.start(queue: DispatchQueue(label: "probe.path.swift"))
        }
        monitor.cancel()
        return outcome
    }

    static func pathMonitorC() async -> Outcome {
        let monitor = nw_path_monitor_create()
        let outcome = await awaitCallback(timeout: 3) { once in
            nw_path_monitor_set_update_handler(monitor) { path in
                let status = nw_path_get_status(path)
                once.resume(Outcome(ok: status == nw_path_status_satisfied, detail: "status \(describe(status))"))
            }
            nw_path_monitor_set_queue(monitor, DispatchQueue(label: "probe.path.c"))
            nw_path_monitor_start(monitor)
        }
        nw_path_monitor_cancel(monitor)
        return outcome
    }

    static func reachability() async -> Outcome {
        await awaitCallback(timeout: timeout) { once in
            DispatchQueue.global().async {
                guard let target = SCNetworkReachabilityCreateWithName(nil, "www.apple.com") else {
                    once.resume(Outcome(ok: false, detail: "create failed"))
                    return
                }
                var flags = SCNetworkReachabilityFlags()
                guard SCNetworkReachabilityGetFlags(target, &flags) else {
                    once.resume(Outcome(ok: false, detail: "get flags failed"))
                    return
                }
                let reachable = flags.contains(.reachable) && !flags.contains(.connectionRequired)
                once.resume(Outcome(ok: reachable, detail: "flags 0x\(String(flags.rawValue, radix: 16))"))
            }
        }
    }

    static func describe(_ status: nw_path_status_t) -> String {
        switch status {
        case nw_path_status_satisfied: "satisfied"
        case nw_path_status_unsatisfied: "unsatisfied"
        case nw_path_status_satisfiable: "satisfiable"
        default: "invalid"
        }
    }
}

@MainActor
final class WebProbe: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    private var continuation: CheckedContinuation<Outcome, Never>?

    func load(_ url: URL) async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.navigationDelegate = self
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: Probes.timeout))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Probes.timeout + 1))
                self?.finish(Outcome(ok: false, detail: "timed out"))
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        webView.stopLoading()
        continuation.resume(returning: outcome)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(Outcome(ok: true, detail: "page loaded"))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }
}
