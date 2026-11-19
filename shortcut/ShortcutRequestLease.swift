import CryptoKit
import Darwin
import Foundation

// Other exported applications may finish scanning for Bluetooth well after a newer
// shortcut was opened. Mark the latest request per identity and serialize their I/O.
final class ShortcutRequestLease {
    private let directory: URL
    private let markers: [URL]
    private var locks: [Int32] = []
    private var token = Data()

    init(serial: String, address: Data?, directory: URL) {
        self.directory = directory
        var keys = serial.isEmpty ? [] : ["edid-" + serial]
        if let address { keys.append("ble-" + address.base64EncodedString()) }
        markers = keys.map {
            let name = SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
            return directory.appendingPathComponent(name)
        }
    }

    func claim() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gate = open(directory.appendingPathComponent("claim.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard gate >= 0 else { throw POSIXError(.EACCES) }
        defer { close(gate) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while flock(gate, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else { throw POSIXError(.EBUSY) }
            usleep(5_000)
        }
        let next = Data(UUID().uuidString.utf8)
        for marker in markers { try next.write(to: marker, options: .atomic) }
        token = next
    }

    var isCurrent: Bool {
        !token.isEmpty && markers.allSatisfy { (try? Data(contentsOf: $0)) == token }
    }

    func acquire() throws -> Bool {
        if locks.count == markers.count { return true }
        for marker in markers {
            let fd = open(marker.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { release(); throw POSIXError(.EACCES) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let error = errno
                close(fd)
                release()
                if error == EWOULDBLOCK { return false }
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            locks.append(fd)
        }
        return true
    }

    func release() {
        for fd in locks { close(fd) }
        locks.removeAll()
    }

    deinit { release() }
}
