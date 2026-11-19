import Foundation

final class StoreTestBluetooth: DisplayBluetooth {
    var onState: ((String) -> Void)?
    var onConnection: ((Bool) -> Void)?
    private(set) var connectionCount = 0
    private(set) var settingWriteCount = 0
    private(set) var queryWriteCount = 0
    private(set) var queries = [Feature]()
    var deferFirstInput = false
    var failFirstInput = false
    private var connected = false
    private var heldInput: (() -> Void)?
    private var values: [Feature: Int] = [.input: 1, .mode: 7, .hdr: 2, .lightPower: 1,
                                          .lightLevel: 1, .lightEffect: 2, .lightColor: 7]

    func submit(_ feature: Feature, value: Int?, reapply: Bool, completion: @escaping (Result<Int, Error>) -> Void) {
        if let value { settingWriteCount += 1; values[feature] = value }
        else { queryWriteCount += 1; queries.append(feature) }
        let reply = {
            if self.failFirstInput && feature == .input {
                self.failFirstInput = false
                completion(.failure(DisplayError("Simulated first connection failure")))
                return
            }
            if !self.connected {
                self.connected = true
                self.connectionCount += 1
                self.onConnection?(true)
            }
            completion(.success(self.values[feature] ?? 1))
        }
        if feature == .input && deferFirstInput {
            deferFirstInput = false
            heldInput = reply
        } else { reply() }
    }
    func releaseInput() { let reply = heldInput; heldInput = nil; reply?() }
    func stop() { connected = false; onConnection?(false) }
}

private final class ResetTestDDC: DDCTransport {
    private var values = ["luminance": 71, "contrast": 31, "input": 7, "volume": 2]
    private(set) var writes = [String]()
    var rejectContrast = false
    func read(_ feature: String, attempt: Int) -> DDCSample {
        DDCSample(status: 0, value: values[feature] ?? 0, maximum: 100, raw: "validated")
    }
    func write(_ feature: String, value: Int) -> Int {
        writes.append(feature)
        if feature == "contrast" && rejectContrast { return -1 }
        values[feature] = value
        return 0
    }
    func invalidate() {}
}

func runStoreActivationTests() {
    func awaitIdle(_ store: DisplayStore) {
        let limit = Date().addingTimeInterval(5)
        while (store.busy || store.isResettingDefaults) && Date() < limit {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        precondition(!store.busy && !store.isResettingDefaults)
    }
    testChannelPreference(awaitIdle: awaitIdle)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let bluetooth = StoreTestBluetooth()
    let transport = ResetTestDDC()
    let ddc = DDCController(log: EventLog(), transport: transport)
    let store = DisplayStore(ddc: ddc, bluetooth: bluetooth, cacheURL: cache, loadCache: false)
    bluetooth.deferFirstInput = true
    store.selectChannel(.bluetooth)
    precondition(bluetooth.queries == [.input])
    for _ in 0..<10 { store.selectChannel(.ddc); store.selectChannel(.bluetooth) }
    precondition(bluetooth.queries == [.input])
    bluetooth.releaseInput()
    awaitIdle(store)
    precondition(bluetooth.connectionCount == 1 && bluetooth.queryWriteCount == 7)
    precondition(ddc.statistics["reads"] == 4)
    for _ in 0..<10 { store.selectChannel(.ddc); store.selectChannel(.bluetooth) }
    precondition(bluetooth.queryWriteCount == 7 && ddc.statistics["reads"] == 4)
    store.disconnectBluetooth()
    precondition(!store.bluetoothConnected)
    store.selectChannel(.ddc); store.selectChannel(.bluetooth)
    precondition(store.bluetoothConnected && bluetooth.connectionCount == 2 && bluetooth.queryWriteCount == 8)
    precondition(bluetooth.queries.last == .input && bluetooth.settingWriteCount == 0)

    // A hardware default is an absolute value. It must work even with no
    // prior brightness/contrast reads and while the displayed page is BLE.
    store.ddcValues = ["volume": 2]
    store.resetDefaults(); awaitIdle(store)
    precondition(store.ddcValues == ["volume": 2, "luminance": 50, "contrast": 50])
    precondition(transport.writes == ["luminance", "contrast"] && bluetooth.settingWriteCount == 0)
    transport.rejectContrast = true
    store.resetDefaults(); awaitIdle(store)
    precondition(store.message.contains("亮度已恢复") && store.message.contains("对比度未确认"))
    precondition(store.ddcValues["volume"] == 2 && transport.writes.count == 4)

    let beforeInputChange = bluetooth.queryWriteCount
    store.selectChannel(.ddc)
    store.setDDC("input", 8); awaitIdle(store)
    precondition(store.noteBLE(.input) == "上次确认" && store.noteDDC("luminance") == "上次确认")
    store.selectChannel(.bluetooth)
    precondition(bluetooth.queries.last == .input && bluetooth.queryWriteCount == beforeInputChange + 1)

    let retryBLE = StoreTestBluetooth()
    retryBLE.failFirstInput = true
    let retry = DisplayStore(ddc: ddc, bluetooth: retryBLE, cacheURL: cache, loadCache: false)
    retry.selectChannel(.bluetooth)
    precondition(!retry.bluetoothConnected && retryBLE.queryWriteCount == 1)
    retry.selectChannel(.ddc); retry.selectChannel(.bluetooth); awaitIdle(retry)
    precondition(retry.bluetoothConnected && retryBLE.queryWriteCount == 8)
    print("PASS: cold and cached page activation, pending-read deduplication, retry after failure, one reconnect query after disconnect")
    print("PASS: defaults set only brightness/contrast, verify each independently, and report partial failure")
}

private func testChannelPreference(awaitIdle: (DisplayStore) -> Void) {
    let suite = "com.local.redmagic-display.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
    let previousStatus = folder.appendingPathComponent("previous.json")
    let transport = ResetTestDDC()
    let ddc = DDCController(log: EventLog(), transport: transport)
    let bluetooth = StoreTestBluetooth()
    func launch(_ preferences: UserDefaults?) -> DisplayStore {
        DisplayStore(ddc: ddc, bluetooth: bluetooth, cacheURL: folder.appendingPathComponent("cache.json"),
                     loadCache: false, channelDefaults: preferences, previousStatusURL: previousStatus)
    }

    let first = launch(defaults)
    precondition(first.channel == .ddc)
    first.selectChannel(.bluetooth)
    let reopened = launch(defaults)
    precondition(reopened.channel == .bluetooth)
    reopened.start()
    awaitIdle(reopened)
    precondition(ddc.statistics["reads"] == 0 && bluetooth.queries.count == 14)
    precondition(bluetooth.settingWriteCount == 0 && transport.writes.isEmpty)

    // A separate diagnostic store cannot replace the user's remembered page.
    let probe = launch(nil)
    precondition(probe.channel == .ddc && probe.statusURL != first.statusURL)
    probe.selectChannel(.bluetooth); probe.selectChannel(.ddc); awaitIdle(probe)
    precondition(launch(defaults).channel == .bluetooth)

    // The old snapshot is consulted once, then subsequent selections take precedence.
    defaults.removePersistentDomain(forName: suite)
    try! Data(#"{"channel":"Bluetooth"}"#.utf8).write(to: previousStatus)
    let upgraded = launch(defaults)
    precondition(upgraded.channel == .bluetooth)
    upgraded.selectChannel(.ddc); awaitIdle(upgraded)
    precondition(launch(defaults).channel == .ddc)
    precondition(transport.writes.isEmpty && bluetooth.settingWriteCount == 0)
    print("PASS: first launch, selection restored in both directions, upgrade migration, probe isolation and read-only transport startup")
}
