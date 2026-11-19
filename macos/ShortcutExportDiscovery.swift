import AppKit
import Foundation

struct ShortcutExportTarget: Equatable {
    let serial: String
    let address: Data?

    var hasBoth: Bool { !serial.isEmpty && address != nil }
    var existingChannelName: String { serial.isEmpty ? tr("蓝牙") : "DDC" }
    var missingChannelName: String { serial.isEmpty ? "DDC" : tr("蓝牙") }

    // Each transport must see exactly one device, and the existing identifier must
    // still match. There is no shared hardware ID between EDID and the BLE profile.
    func addingUniquePeer(ddc: DDCDiscoveryResult, bluetooth: MonitorDiscovery.Scan) -> Self {
        guard !hasBoth, !serial.isEmpty || address != nil,
              ddc.matchedCount == 1, ddc.serials.count == 1, let currentSerial = ddc.serials.first,
              !currentSerial.isEmpty, bluetooth.observedCount == 1, bluetooth.candidates.count == 1,
              let currentAddress = bluetooth.candidates.first?.address,
              (serial.isEmpty || serial == currentSerial), (address == nil || address == currentAddress)
        else { return self }
        return Self(serial: currentSerial, address: currentAddress)
    }
}

/// One export owns its read-only discovery. Cancelling the save panel never changes
/// the app's selected monitor, preferences, or normal control connection.
@MainActor
final class ShortcutExportDiscovery: NSObject {
    private(set) var target: ShortcutExportTarget
    private var scanner: MonitorDiscovery?
    private var ddc: DDCDiscoveryResult?
    private var bluetooth: MonitorDiscovery.Scan?
    private var continuation: CheckedContinuation<ShortcutExportTarget, Never>?
    var onMessage: ((String) -> Void)?

    init(target: ShortcutExportTarget) {
        self.target = target
    }

    func start() {
        if target.hasBoth {
            onMessage?(tr("优先使用 DDC，必要时自动尝试蓝牙。"))
            return
        }
        onMessage?(tr("正在检查另一种连接。若发现多台显示器，本次仅使用%@。需要双通道时，请先在%@页选择目标再导出。", target.existingChannelName, target.missingChannelName))
        let bluetoothScanner = MonitorDiscovery()
        scanner = bluetoothScanner
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = DDCDiscovery.scan()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanner != nil else { return }
                self.ddc = result
                self.update()
            }
        }
        bluetoothScanner.start { [weak self] result in
            guard let self, self.scanner != nil else { return }
            switch result {
            case .success(let inventory):
                self.bluetooth = inventory
                self.update()
            case .failure:
                self.finish()
            }
        }
    }

    private func update() {
        // An empty or ambiguous inventory cannot produce a paired target. No need
        // to wait for the other transport if this one is already conclusive.
        if let ddc, ddc.matchedCount != 1 || ddc.serials.count != 1 {
            finish(ambiguous: ddc.matchedCount > 1)
            return
        }
        if let bluetooth, bluetooth.observedCount != 1 || bluetooth.candidates.count != 1 {
            finish(ambiguous: bluetooth.observedCount > 1)
            return
        }
        if let ddc, let bluetooth {
            target = target.addingUniquePeer(ddc: ddc, bluetooth: bluetooth)
            finish()
        }
    }

    @objc private func finishWithCurrentChannel() {
        finish()
    }

    func cancel() {
        onMessage = nil
        finish()
    }

    private func finish(ambiguous: Bool = false) {
        guard let scanner else { return }
        self.scanner = nil
        scanner.cancel()
        if target.hasBoth {
            onMessage?(tr("优先使用 DDC，必要时自动尝试蓝牙。"))
        } else if ambiguous {
            onMessage?(tr("发现多台显示器，本次仅使用%@。请在%@页选择目标后重新导出。", target.existingChannelName, target.missingChannelName))
        } else {
            onMessage?(tr("未能同时验证两个通道，本次仅使用%@。", target.existingChannelName))
        }
        let pending = continuation
        continuation = nil
        pending?.resume(returning: target)
    }

    /// Usually identification finishes while the person chooses a filename. If
    /// Save is pressed sooner, keep the automatic fallback and offer an immediate
    /// single-channel export. A pending privacy prompt can't hold the save forever.
    func targetForExport() async -> ShortcutExportTarget {
        guard scanner != nil else { return target }
        let alert = NSAlert()
        alert.messageText = tr("正在识别显示器…")
        alert.informativeText = tr("识别结束后将自动导出，也可以立即使用%@导出。", target.existingChannelName)
        let button = alert.addButton(withTitle: tr("立即使用%@导出", target.existingChannelName))
        button.target = self
        button.action = #selector(finishWithCurrentChannel)
        let window = alert.window
        window.center()
        window.makeKeyAndOrderFront(nil)
        let deadline = DispatchWorkItem { [weak self] in self?.finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: deadline)
        defer {
            deadline.cancel()
            window.orderOut(nil)
        }
        return await withCheckedContinuation { continuation in
            if scanner == nil { continuation.resume(returning: target) }
            else { self.continuation = continuation }
        }
    }
}
