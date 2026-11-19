import Foundation

final class StoreTestBluetooth: DisplayBluetooth {
    var onState: ((String) -> Void)?
    var onConnection: ((Bool) -> Void)?
    private(set) var connectionCount = 0
    private(set) var settingWriteCount = 0
    private(set) var queryWriteCount = 0
    private(set) var queries = [Feature]()
    private(set) var inputWrites = [(target: Int, forced: Bool)]()
    var deferFirstInput = false
    var failFirstInput = false
    var rejectInputWrite = false
    private var connected = false
    private var heldInput: (() -> Void)?
    private var values: [Feature: Int] = [.input: 1, .mode: 7, .hdr: 2, .lightPower: 1,
                                          .lightLevel: 1, .lightEffect: 2, .lightColor: 7]

    func submit(_ feature: Feature, value: Int?, reapply: Bool, completion: @escaping (Result<Int, Error>) -> Void) {
        if feature == .input, let value {
            inputWrites.append((value, reapply))
            if rejectInputWrite { completion(.failure(DisplayError("Unconfirmed menu"))); return }
        }
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
    func externalInput(_ value: Int) { values[.input] = value }
    func stop() { connected = false; onConnection?(false) }
}

private final class ResetTestDDC: DDCTransport {
    private var values = ["luminance": 71, "contrast": 31, "input": 7, "volume": 2]
    private(set) var writes = [String]()
    var rejectContrast = false
    var failInputRead = false
    func read(_ feature: String, attempt: Int) -> DDCSample {
        DDCSample(status: feature == "input" && failInputRead ? 1 : 0,
                  value: values[feature] ?? 0, maximum: 100, raw: "test")
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
    testDiscoveryOnFirstUse(awaitIdle: awaitIdle)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: cache) }
    let bluetooth = StoreTestBluetooth()
    let transport = ResetTestDDC()
    let ddc = DDCController(log: EventLog(), transport: transport)
    var time = Date()
    let store = DisplayStore(ddc: ddc, bluetooth: bluetooth, cacheURL: cache, loadCache: false, now: { time })
    store.showingDonations = true
    store.panelOpened()
    precondition(store.channel == .ddc && !store.busy && ddc.statistics["reads"] == 0 && bluetooth.queries.isEmpty)
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
    store.showingDonations = true
    store.panelOpened()
    precondition(store.channel == .bluetooth && bluetooth.connectionCount == 1 && bluetooth.queryWriteCount == 7)
    store.selectChannel(.bluetooth)
    precondition(!store.showingDonations)
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
    precondition(store.message.contains(tr("%@已恢复到 50。", tr("亮度"))) && store.message.contains(tr("%@未确认恢复，请刷新检查", tr("对比度"))))
    precondition(store.ddcValues["volume"] == 2 && transport.writes.count == 4)

    store.selectChannel(.ddc)
    store.setDDC("input", 8); awaitIdle(store)
    precondition(store.values[.input] == 2 && store.noteBLE(.input).isEmpty && store.noteDDC("luminance") == tr("上次确认"))
    precondition(bluetooth.inputWrites.count == 1 && bluetooth.inputWrites[0].target == 2 && bluetooth.inputWrites[0].forced)
    store.selectChannel(.bluetooth)
    let beforeReopen = bluetooth.queryWriteCount
    // Another host changed the menu while this panel was closed. Only the input
    // is re-read; repeated opens during the query reuse the same connection.
    time.addTimeInterval(6)
    bluetooth.externalInput(1)
    bluetooth.deferFirstInput = true
    store.panelOpened(); store.panelOpened()
    precondition(store.noteBLE(.input) == tr("上次确认") && store.inputMismatch == nil)
    precondition(bluetooth.queries.last == .input && bluetooth.queryWriteCount == beforeReopen + 1)
    bluetooth.releaseInput()
    store.selectChannel(.ddc); awaitIdle(store)
    precondition(store.inputMismatch?.active == "DP" && store.inputMismatch?.menu == "Type-C")
    store.selectChannel(.bluetooth); store.panelOpened()
    precondition(bluetooth.queryWriteCount == beforeReopen + 1 && bluetooth.inputWrites.count == 1)
    store.set(.input, 1)
    precondition(bluetooth.inputWrites.last?.forced == true && bluetooth.inputWrites.count == 2)
    precondition(store.inputMismatch == nil && store.noteDDC("input") == tr("上次确认"))
    store.disconnectBluetooth()
    precondition(store.noteBLE(.input) == tr("上次确认"))

    testDDCMenuSync(cache: cache, awaitIdle: awaitIdle)

    let retryBLE = StoreTestBluetooth()
    retryBLE.failFirstInput = true
    let retry = DisplayStore(ddc: ddc, bluetooth: retryBLE, cacheURL: cache, loadCache: false)
    retry.selectChannel(.bluetooth)
    precondition(!retry.bluetoothConnected && retryBLE.queryWriteCount == 1)
    retry.selectChannel(.ddc); retry.selectChannel(.bluetooth); awaitIdle(retry)
    precondition(retry.bluetoothConnected && retryBLE.queryWriteCount == 8)
    print("PASS: cold and cached page activation, pending-read deduplication, retry after failure, one reconnect query after disconnect")
    print("PASS: recheck only the visible input on reopen, compare independent recent reads, force explicit menu selection")
    print("PASS: defaults set only brightness/contrast, verify each independently, and report partial failure")
}

private func testDDCMenuSync(cache: URL, awaitIdle: (DisplayStore) -> Void) {
    let bluetooth = StoreTestBluetooth()
    let transport = ResetTestDDC()
    let ddc = DDCController(log: EventLog(), transport: transport)
    var authorized = false
    let store = DisplayStore(ddc: ddc, bluetooth: bluetooth, cacheURL: cache,
                             loadCache: false, canSyncMenu: { authorized })
    store.setDDC("input", 8); awaitIdle(store)
    precondition(bluetooth.connectionCount == 0 && bluetooth.inputWrites.isEmpty)
    precondition(store.message == tr("%@。可在蓝牙页选择 %@ 同步显示器菜单", tr("DDC 已确认 %@", "DP"), "DP"))

    authorized = true
    store.setDDC("input", 6); awaitIdle(store)
    precondition(bluetooth.inputWrites.count == 1 && bluetooth.inputWrites[0].target == 4)
    precondition(bluetooth.inputWrites[0].forced && store.message == tr("%@，蓝牙已确认菜单为 %@", tr("DDC 已确认 %@", "HDMI 2"), "HDMI 2"))
    bluetooth.rejectInputWrite = true
    store.setDDC("input", 5); awaitIdle(store)
    precondition(store.noteDDC("input").isEmpty && store.noteBLE(.input) == tr("待确认"))
    precondition(store.message == tr("%@。蓝牙未能确认菜单设置，请在蓝牙页重试", tr("DDC 已确认 %@", "HDMI 1")))

    transport.failInputRead = true
    bluetooth.rejectInputWrite = false
    store.setDDC("input", 7); awaitIdle(store)
    precondition(store.message == tr("%@，蓝牙已确认菜单为 %@", tr("DDC 已发送，活动输入尚未确认"), "Type-C"))
    precondition(store.noteDDC("input") == tr("待确认") && store.noteBLE(.input).isEmpty)

    transport.failInputRead = false
    let before = bluetooth.inputWrites.count
    store.setDDC("input", 8)
    store.disconnectBluetooth()
    awaitIdle(store)
    precondition(bluetooth.inputWrites.count == before)
    print("PASS: DDC input sync checks Bluetooth authorization, verifies menu separately, cancels on explicit disconnect")
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


private func testDiscoveryOnFirstUse(awaitIdle: (DisplayStore) -> Void) {
    let suite = "com.local.redmagic-display.tests." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    let bindings = MonitorBindings(defaults: preferences)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: cache)
    }
    let transport = ResetTestDDC()
    let controller = DDCController(log: EventLog(), transport: transport)
    let bluetooth = StoreTestBluetooth()
    func launch(_ scan: @escaping () -> DDCDiscoveryResult) -> DisplayStore {
        DisplayStore(ddc: controller, bluetooth: bluetooth, cacheURL: cache, loadCache: false,
                     bindings: bindings, scanDDC: scan)
    }

    let empty = launch { DDCDiscoveryResult(serials: [], matchedCount: 0) }
    var completed = false
    empty.onRefreshComplete = { completed = true }
    empty.refresh()
    awaitIdle(empty)
    precondition(completed && empty.needsBinding && empty.bindingOptions.isEmpty)

    let ambiguous = launch { DDCDiscoveryResult(serials: ["Fixture A"], matchedCount: 2) }
    ambiguous.start()
    awaitIdle(ambiguous)
    precondition(ambiguous.needsBinding && ambiguous.bindingOptions == ["Fixture A"])
    ambiguous.chooseMonitor("unknown")
    precondition(bindings.serial.isEmpty && controller.statistics["reads"] == 0)
    ambiguous.chooseMonitor("Fixture A")
    awaitIdle(ambiguous)
    precondition(bindings.serial == "Fixture A" && !ambiguous.needsBinding)

    let saved = launch { preconditionFailure("Existing binding must skip discovery") }
    saved.start()
    awaitIdle(saved)
    precondition(!saved.needsBinding && saved.bindingOptions.isEmpty)
    bindings.bindIfMissing("Fixture B", to: .ddc)
    precondition(bindings.serial == "Fixture A")
    preferences.removeObject(forKey: "MonitorSerial")

    let single = launch { DDCDiscoveryResult(serials: ["Fixture B"], matchedCount: 1) }
    single.start()
    single.showingDonations = true
    single.selectChannel(.ddc)
    // The cancelled scan can finish after the replacement scan has started.
    awaitIdle(single)
    precondition(bindings.serial == "Fixture B" && !single.needsBinding)
    bindings.bindIfMissing("invalid address", to: .bluetooth)
    precondition(bindings.address == nil)
    bindings.bindIfMissing("01:02:03:04:05:06", to: .bluetooth)
    bindings.bindIfMissing("10:20:30:40:50:60", to: .bluetooth)
    precondition(bindings.address == Data([1, 2, 3, 4, 5, 6]))
    let switcher = launch { DDCDiscoveryResult(serials: ["Fixture C"], matchedCount: 1) }
    var replaced = false
    switcher.onMonitorReplaced = { replaced = true }
    switcher.selectAnotherMonitor()
    awaitIdle(switcher)
    precondition(switcher.selectingReplacement && bindings.serial == "Fixture B")
    switcher.chooseMonitor("Fixture C")
    precondition(replaced && bindings.serial == "Fixture C" && bindings.address == nil)
    precondition(bluetooth.queries.isEmpty && bluetooth.settingWriteCount == 0 && transport.writes.isEmpty)
    print("PASS: first-use discovery, ambiguous target selection, saved bindings, retry after cancellation and read-only startup")
}
