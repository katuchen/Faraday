import NetworkExtension
import FaradayCore

final class FilterDataProvider: NEFilterDataProvider {
    private static let peekBytes = 64 * 1024

    private let engine = FilterEngine.shared
    private let log = Log.logger("provider")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        engine.attach(self)
        let settings = NEFilterSettings(rules: [], defaultAction: .filterData)
        nonisolated(unsafe) let completion = completionHandler
        apply(settings) { [log] error in
            if let error {
                log.error("Applying filter settings failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("Filter started")
            }
            completion(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("Filter stopped, reason \(reason.rawValue)")
        engine.detach(self)
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow else { return .allow() }
        let origin = engine.resolver.origin(
            appAuditToken: flow.sourceAppAuditToken,
            processAuditToken: flow.sourceProcessAuditToken
        )
        switch engine.newFlowAction(for: socketFlow, origin: origin) {
        case .allow:
            return .allow()
        case .drop:
            log.info("Dropped new flow to \(socketFlow.remoteHostname ?? String(describing: socketFlow.remoteFlowEndpoint), privacy: .public) from \(String(describing: origin), privacy: .public)")
            return .drop()
        case .watch:
            return .filterDataVerdict(
                withFilterInbound: true, peekInboundBytes: Self.peekBytes,
                filterOutbound: true, peekOutboundBytes: Self.peekBytes
            )
        }
    }

    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        dataVerdict(for: flow, passing: readBytes.count)
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        dataVerdict(for: flow, passing: readBytes.count)
    }

    override func handleInboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        engine.flowFinished(flow, direction: .inbound)
        return .allow()
    }

    override func handleOutboundDataComplete(for flow: NEFilterFlow) -> NEFilterDataVerdict {
        engine.flowFinished(flow, direction: .outbound)
        return .allow()
    }

    private func dataVerdict(for flow: NEFilterFlow, passing byteCount: Int) -> NEFilterDataVerdict {
        switch engine.dataAction(for: flow) {
        case .stopWatching:
            return .allow()
        case .drop:
            log.info("Cut an open flow of an offline simulator")
            return .drop()
        case .keepWatching:
            return NEFilterDataVerdict(passBytes: byteCount, peekBytes: Self.peekBytes)
        }
    }
}
