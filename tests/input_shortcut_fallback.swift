import Foundation

private final class Scenario {
    var ddcCalls: [Int] = []
    var bleCalls: [Int?] = []
    var ddcReply: ShortcutSwitch.Reply?
    var bleReply: ShortcutSwitch.Reply?
    var outcome: ShortcutOutcome?
    var current = true
    var settingSent = false

    init(_ port: MonitorInput, ddc: Bool = true, ble: Bool = true) {
        let action = ShortcutSwitch(input: port, sendDDC: ddc ? { value, reply in
            self.ddcCalls.append(value); self.ddcReply = reply
        } : nil, submitBLE: ble ? { value, reply in
            self.bleCalls.append(value); self.bleReply = reply
        } : nil, bleHasSent: { self.settingSent }, current: { self.current }, finish: { self.outcome = $0 })
        action.start()
    }

    func confirm(_ channel: String) {
        guard case .confirmed(let actual) = outcome, actual.contains(channel) else { preconditionFailure() }
    }
}

@main
struct InputShortcutFallbackChecks {
    static func main() throws {
        for port in MonitorInput.ports {
            let ddc = Scenario(port)
            precondition(ddc.ddcCalls == [port.ddc])
            ddc.ddcReply?(.success(port.ddc))
            ddc.confirm("DDC")
            precondition(ddc.bleCalls.isEmpty)

            let fallback = Scenario(port)
            fallback.ddcReply?(.failure(DDCOperationError.unavailable))
            precondition(fallback.bleCalls == [port.bluetooth])
            fallback.bleReply?(.success(port.bluetooth))
            fallback.confirm("蓝牙")

            let already = Scenario(port)
            already.ddcReply?(.failure(DDCOperationError.unconfirmed))
            already.bleReply?(.success(port.bluetooth))
            precondition(already.outcome == nil && already.bleCalls == [nil, nil])
            already.bleReply?(.success(port.bluetooth))
            already.confirm("蓝牙菜单")
            precondition(already.bleCalls == [nil, nil])

            let changed = Scenario(port)
            changed.ddcReply?(.failure(DDCOperationError.unconfirmed))
            changed.bleReply?(.success(port.bluetooth))
            changed.bleReply?(.success(0))
            precondition(changed.bleCalls == [nil, nil, port.bluetooth])
            changed.bleReply?(.success(port.bluetooth))
            changed.confirm("蓝牙")
        }
        let port = MonitorInput.ports[0]
        let denied = Scenario(port, ddc: false)
        denied.bleReply?(.failure(DisplayError("蓝牙权限被拒绝")))
        guard case .failed(let message) = denied.outcome, message.contains("权限") else { preconditionFailure() }
        precondition(denied.ddcCalls.isEmpty)

        let timeout = Scenario(port)
        timeout.ddcReply?(.failure(DDCOperationError.unconfirmed))
        timeout.bleReply?(.failure(DisplayError("读菜单超时")))
        guard case .unconfirmed(let detail) = timeout.outcome, detail.contains("超时") else { preconditionFailure() }
        precondition(timeout.bleCalls == [nil])

        let disconnected = Scenario(port, ddc: false)
        disconnected.settingSent = true
        disconnected.bleReply?(.failure(DisplayError("蓝牙已断开")))
        guard case .unconfirmed = disconnected.outcome else { preconditionFailure() }

        let legacy = Scenario(port, ble: false)
        legacy.ddcReply?(.failure(DDCOperationError.unavailable))
        guard case .failed = legacy.outcome else { preconditionFailure() }
        precondition(legacy.bleCalls.isEmpty)

        let superseded = Scenario(port)
        superseded.ddcReply?(.failure(DDCOperationError.unconfirmed))
        superseded.current = false
        superseded.bleReply?(.success(0))
        precondition(superseded.bleCalls == [nil] && superseded.outcome == nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let address = Data([0, 1, 2, 3, 4, 5])
        let first = ShortcutRequestLease(serial: "Test Serial", address: address, directory: directory)
        let next = ShortcutRequestLease(serial: "", address: address, directory: directory)
        let unrelated = ShortcutRequestLease(serial: "Other Serial", address: nil, directory: directory)
        try first.claim()
        let firstAcquired = try first.acquire()
        precondition(first.isCurrent && firstAcquired)
        try next.claim()
        let held = try next.acquire()
        precondition(!first.isCurrent && next.isCurrent && !held)
        first.release()
        let secondAcquired = try next.acquire()
        precondition(secondAcquired)
        try unrelated.claim()
        let independent = try unrelated.acquire()
        precondition(next.isCurrent && unrelated.isCurrent && independent)
        print("PASS: DDC, both BLE fallback paths, two matching reports, bindings, permission/timeout, and overlapping shortcuts")
    }
}
