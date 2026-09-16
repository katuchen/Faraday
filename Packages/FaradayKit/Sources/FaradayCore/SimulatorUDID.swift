import Foundation

public struct SimulatorUDID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ string: some StringProtocol) {
        guard string.utf8.count == 36, let uuid = UUID(uuidString: String(string)) else { return nil }
        rawValue = uuid.uuidString
    }

    public var description: String { rawValue }

    public static func < (lhs: SimulatorUDID, rhs: SimulatorUDID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension SimulatorUDID: Codable {
    public init(from decoder: any Decoder) throws {
        let string = try String(from: decoder)
        guard let udid = SimulatorUDID(string) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid simulator UDID: \(string)")
            )
        }
        self = udid
    }

    public func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}
