import Foundation

struct DDCDiscoveryResult {
    let serials: [String]
    let matchedCount: Int

    var uniqueSerial: String? { matchedCount == 1 ? serials.first : nil }
}

enum DDCDiscovery {
    /// Reads the EDID of each external display. Call off the main thread.
    static func scan() -> DDCDiscoveryResult {
        var count = 0
        let serials = GMDDCDiscoverSerials(&count)
        return DDCDiscoveryResult(serials: serials, matchedCount: count)
    }
}
