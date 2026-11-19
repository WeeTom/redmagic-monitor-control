import Darwin
import Foundation

@main
struct BluetoothTransactionLockTests {
    static let first = Data([1, 2, 3, 4, 5, 6])
    static let second = Data([1, 2, 3, 4, 5, 7])

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4 {
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            let lock = BluetoothTransactionLock(address: args[3] == "first" ? first : second,
                                                directory: directory)
            guard try lock.tryAcquire() else { exit(2) }
            if args[1] == "hold" {
                FileHandle.standardOutput.write(Data([1]))
                _ = FileHandle.standardInput.readData(ofLength: 1)
            }
            exit(0)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func child(_ command: String, _ address: String) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0])
            process.arguments = [command, dir.path, address]
            return process
        }
        func probe(_ address: String) throws -> Int32 {
            let process = child("try", address)
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        let parent = BluetoothTransactionLock(address: first, directory: dir)
        let acquired = try parent.tryAcquire()
        precondition(acquired && parent.isHeld)
        let blocked = try probe("first")
        let independent = try probe("second")
        precondition(blocked == 2 && independent == 0)
        parent.release()
        precondition(!parent.isHeld)
        let afterRelease = try probe("first")
        precondition(afterRelease == 0)

        let holder = child("hold", "first")
        let ready = Pipe(), input = Pipe()
        holder.standardOutput = ready
        holder.standardInput = input
        try holder.run()
        precondition(ready.fileHandleForReading.readData(ofLength: 1) == Data([1]))
        let contended = try parent.tryAcquire()
        precondition(!contended && !parent.isHeld)
        holder.terminate()
        holder.waitUntilExit()
        let recovered = try parent.tryAcquire()
        precondition(recovered && parent.isHeld)
        parent.release()

        // A bad lock directory fails closed, distinguishable from contention.
        let badDir = dir.appendingPathComponent("file")
        try Data().write(to: badDir)
        let broken = BluetoothTransactionLock(address: first, directory: badDir)
        do {
            _ = try broken.tryAcquire()
            preconditionFailure("Expected an error opening the lock")
        } catch {
            precondition(!broken.isHeld)
        }
        print("Bluetooth transaction lock passed: cross-process exclusion, independent targets, release, owner exit, open failure")
    }
}
