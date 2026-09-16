import Foundation
import FaradayCore

final class ControlService: NSObject, NSXPCListenerDelegate, FaradayControlProtocol, @unchecked Sendable {
    static let shared = ControlService()

    private var listener: NSXPCListener?
    private let engine = FilterEngine.shared
    private let log = Log.logger("control")

    func start() {
        guard let networkExtension = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
              let machServiceName = networkExtension["NEMachServiceName"] as? String
        else {
            log.fault("NEMachServiceName is missing from Info.plist")
            return
        }
        let listener = NSXPCListener(machServiceName: machServiceName)
        if let requirement = Self.clientRequirement() {
            listener.setConnectionCodeSigningRequirement(requirement)
        }
        listener.delegate = self
        listener.resume()
        self.listener = listener
        log.info("Listening on \(machServiceName, privacy: .public)")
    }

    private static func clientRequirement() -> String? {
        let info = Bundle.main
        guard let team = info.object(forInfoDictionaryKey: FaradayInfoKey.teamIdentifier) as? String, !team.isEmpty,
              let app = info.object(forInfoDictionaryKey: FaradayInfoKey.appBundleIdentifier) as? String,
              let cli = info.object(forInfoDictionaryKey: FaradayInfoKey.cliIdentifier) as? String
        else {
            return nil
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (identifier \"\(app)\" or identifier \"\(cli)\")"
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ControlInterface.make()
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: FaradayControlProtocol

    func fetchStatus(reply: @escaping @Sendable (Data?, String?) -> Void) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            reply(try encoder.encode(engine.status()), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func setOffline(_ offline: Bool, udid: String, reply: @escaping @Sendable (String?) -> Void) {
        guard let udid = SimulatorUDID(udid) else {
            reply("Invalid simulator UDID: \(udid)")
            return
        }
        engine.setOffline(offline, udid: udid)
        reply(nil)
    }

    func setAllOnline(reply: @escaping @Sendable (String?) -> Void) {
        engine.setAllOnline()
        reply(nil)
    }

    func setBootedSimulators(_ udids: [String], reply: @escaping @Sendable (String?) -> Void) {
        engine.setBootedSimulators(Set(udids.compactMap(SimulatorUDID.init)))
        reply(nil)
    }

    func setKillExistingConnections(_ enabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        engine.setKillExistingConnections(enabled)
        reply(nil)
    }
}
