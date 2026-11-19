import Foundation
import CryptoKit

enum MonitorIdentity {
    static let bindings: MonitorBindings = {
        let domain = "com.local.redmagic-display"
        let defaults: UserDefaults
        if Bundle.main.bundleIdentifier == domain {
            defaults = .standard
        } else {
            defaults = UserDefaults(suiteName: domain) ?? .standard
        }
        return MonitorBindings(defaults: defaults)
    }()
    static var serial: String { bindings.serial }
    static var address: Data? { bindings.address }

    static func parseAddress(_ raw: String) -> Data? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var result = Data()
        for part in parts {
            guard part.utf8.count == 2, part.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let byte = UInt8(part, radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }

}

struct MonitorBindings {
    let defaults: UserDefaults

    var serial: String {
        defaults.string(forKey: "MonitorSerial")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    var address: Data? {
        defaults.string(forKey: "BluetoothAddress").flatMap(MonitorIdentity.parseAddress)
    }
    var cacheKey: String {
        let suffix = address?.map { String(format: "%02X", $0) }.joined() ?? ""
        let bytes = Data((serial + "\u{0}" + suffix).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    /// Changing the physical target invalidates the other transport's independently acquired identity.
    func replaceMonitor(with identifier: String, on channel: ControlChannel) {
        defaults.removeObject(forKey: "MonitorSerial")
        defaults.removeObject(forKey: "BluetoothAddress")
        bindIfMissing(identifier, to: channel)
    }
    func bindIfMissing(_ identifier: String, to channel: ControlChannel) {
        switch channel {
        case .ddc:
            if serial.isEmpty && !identifier.isEmpty { defaults.set(identifier, forKey: "MonitorSerial") }
        case .bluetooth:
            if address == nil && MonitorIdentity.parseAddress(identifier) != nil {
                defaults.set(identifier, forKey: "BluetoothAddress")
            }
        }
    }
}
