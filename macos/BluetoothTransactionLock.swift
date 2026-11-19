import CryptoKit
import Darwin
import Foundation

// Every client of a monitor receives the same untagged GATT replies. Hold this
// lock from the first query through the final reply of a single protocol job.
final class BluetoothTransactionLock {
    private let file: URL
    private var descriptor: Int32 = -1
    var isHeld: Bool { descriptor >= 0 }

    init(address: Data, directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RedMagicDisplay", isDirectory: true)) {
        let key = SHA256.hash(data: address).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent("ble-" + key + ".lock")
    }

    // Returns false on contention so the CoreBluetooth delegate queue can keep running.
    func tryAcquire() throws -> Bool {
        if isHeld { return true }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            descriptor = fd
            return true
        }
        let error = errno
        close(fd)
        if error == EWOULDBLOCK || error == EINTR { return false }
        throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
    }

    func release() {
        guard isHeld else { return }
        close(descriptor) // A crash or process exit also releases the flock.
        descriptor = -1
        // Keep the file in place so contenders always lock the same inode.
    }

    deinit { release() }
}
