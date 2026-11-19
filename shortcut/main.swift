import AppKit
import Foundation

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
let diagnose = arguments == ["--diagnose"]

func report(_ title: String, _ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("\(title) — \(message)\n".utf8))
    if status == 1 && !diagnose && isatty(STDERR_FILENO) == 0 {
        // Finder has no stderr. Keep the alert independent so it cannot delay a later launch.
        let alert = Process()
        alert.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        alert.arguments = ["-e", "on run args\n display alert (item 1 of args) message (item 2 of args) giving up after 8\nend run", title, message]
        alert.standardOutput = FileHandle.nullDevice
        alert.standardError = FileHandle.nullDevice
        try? alert.run()
    }
    exit(status)
}

guard arguments.isEmpty || diagnose else {
    FileHandle.standardError.write(Data("用法：InputShortcutRunner [--diagnose]\n".utf8))
    exit(64)
}

let info = Bundle.main.infoDictionary ?? [:]
let serial = (info["GMMonitorSerial"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
let rawAddress = info["GMBluetoothAddress"] as? String
let address = rawAddress.flatMap(MonitorIdentity.parseAddress)
guard let value = info["GMInputSource"] as? Int,
      let input = MonitorInput.ports.first(where: { $0.ddc == value }),
      !serial.utf8.contains(0), !serial.isEmpty || address != nil,
      rawAddress == nil || address != nil else {
    report("快捷方式配置无效", "请在红魔显示器中为目标显示器重新导出快捷方式。", status: 1)
}
if diagnose {
    print("\(input.name) (DDC \(input.ddc)); DDC=\(serial.isEmpty ? "no" : "yes"), Bluetooth=\(address == nil ? "no" : "yes")")
    exit(0)
}

final class ShortcutDelegate: NSObject, NSApplicationDelegate {
    let input: MonitorInput
    let address: Data?
    let log = EventLog()
    let lease: ShortcutRequestLease
    let ddc: DDCController?
    private var bluetooth: BluetoothController?
    private var request = 0
    private var waiting = false
    private var waitDeadline: TimeInterval = 0
    private var timer: Timer?

    init(input: MonitorInput, serial: String, address: Data?) {
        self.input = input
        self.address = address
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.local.redmagic-display/shortcut-inputs", isDirectory: true)
        lease = ShortcutRequestLease(serial: serial, address: address, directory: cache)
        ddc = serial.isEmpty ? nil : DDCController(log: log, transport: NativeDDCTransport(serial: serial, writeLockTimeout: 2))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkRequest() }
        switchInput()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if request > 0 { switchInput() }
        return false
    }

    private func switchInput() {
        request += 1
        do { try lease.claim() }
        catch { finish(.failed("无法记录快捷方式请求。\(error.localizedDescription)")) }
        bluetooth?.stop()
        bluetooth = nil
        waiting = true
        waitDeadline = ProcessInfo.processInfo.systemUptime + 5
        checkRequest()
    }

    private func checkRequest() {
        guard lease.isCurrent else {
            log.record("shortcut_superseded", ["source": input.name])
            exit(0)
        }
        guard waiting else { return }
        do {
            guard try lease.acquire() else {
                if ProcessInfo.processInfo.systemUptime >= waitDeadline { finish(.failed("另一项切换尚未结束，请稍后重试。")) }
                return
            }
        } catch { finish(.failed("无法取得目标显示器的快捷方式锁。\(error.localizedDescription)")) }
        waiting = false
        let current = request
        let wake = Process()
        wake.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        wake.arguments = ["-u", "-t", "3"]
        do { try wake.run() } catch { log.record("shortcut_wake_failed", ["message": error.localizedDescription]) }

        log.record("shortcut_input", ["source": input.name, "value": input.ddc])
        let action = ShortcutSwitch(input: input, sendDDC: ddc.map { controller in
            { value, reply in controller.write("input", value: value, completion: reply) }
        }, submitBLE: address.map { address in
            { value, reply in
                if self.bluetooth == nil { self.bluetooth = BluetoothController(log: self.log, address: address) }
                self.bluetooth?.submit(.input, value: value, reapply: value != nil, completion: reply)
            }
        }, bleHasSent: { (self.bluetooth?.settingWriteCount ?? 0) > 0 },
           current: { self.request == current && self.lease.isCurrent }, finish: { self.finish($0) })
        action.start()
    }

    private func finish(_ outcome: ShortcutOutcome) -> Never {
        lease.release()
        switch outcome {
        case .confirmed(let channel):
            log.record("shortcut_confirmed", ["source": input.name, "channel": channel])
            exit(0)
        case .unconfirmed(let detail):
            log.record("shortcut_sent_unconfirmed", ["source": input.name, "message": detail])
            report("切换到 \(input.name) 尚未确认", detail, status: 2)
        case .failed(let detail):
            log.record("shortcut_failed", ["source": input.name, "message": detail])
            report("切换到 \(input.name) 失败", detail, status: 1)
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = ShortcutDelegate(input: input, serial: serial, address: address)
app.delegate = delegate
app.run()
