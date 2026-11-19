import Foundation
import CryptoKit

enum MonitorIdentity {
    private static let settings = UserDefaults.standard.persistentDomain(forName: "com.local.redmagic-display")
    static let serial = (settings?["MonitorSerial"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    static let address = (settings?["BluetoothAddress"] as? String).flatMap(parseAddress)

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

    static let addressSuffix = address?.map { String(format: "%02X", $0) }.joined()
    static let cacheKey: String = {
        let bytes = Data((serial + "\u{0}" + (addressSuffix ?? "")).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }()
}
