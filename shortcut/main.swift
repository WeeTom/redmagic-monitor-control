import AppKit
import Foundation

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
let diagnose = arguments == ["--diagnose"]

func report(_ title: String, _ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("\(title) — \(message)\n".utf8))
    if status == 1 && !diagnose && isatty(STDERR_FILENO) == 0 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        // A launcher used by automation must exit even when the display has switched away.
        let timer = Timer(timeInterval: 8, repeats: false) { _ in app.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        alert.window.center()
        alert.window.orderFrontRegardless()
        alert.runModal()
        timer.invalidate()
    }
    exit(status)
}

guard arguments.isEmpty || diagnose else {
    FileHandle.standardError.write(Data("用法：InputShortcutRunner [--diagnose]\n".utf8))
    exit(64)
}

let info = Bundle.main.infoDictionary ?? [:]
guard let value = info["GMInputSource"] as? Int,
      let input = MonitorInput.ports.first(where: { $0.ddc == value }),
      let rawSerial = info["GMMonitorSerial"] as? String else {
    report("快捷方式配置无效", "请在红魔显示器中重新导出快捷方式。", status: 1)
}
let serial = rawSerial.trimmingCharacters(in: .whitespacesAndNewlines)
guard !serial.isEmpty, !serial.utf8.contains(0) else {
    report("快捷方式缺少有效的显示器序列号", "请为目标显示器重新导出快捷方式。", status: 1)
}
if diagnose {
    print("\(input.name) (DDC \(input.ddc))")
    exit(0)
}

final class ShortcutDelegate: NSObject, NSApplicationDelegate {
    let input: MonitorInput
    let log: EventLog
    let controller: DDCController
    private var request = 0

    init(input: MonitorInput, serial: String) {
        self.input = input
        log = EventLog()
        controller = DDCController(log: log, transport: NativeDDCTransport(serial: serial, writeLockTimeout: 2))
    }

    func applicationDidFinishLaunching(_ notification: Notification) { switchInput() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if request > 0 { switchInput() }
        return false
    }

    private func switchInput() {
        request += 1
        let current = request
        let wake = Process()
        wake.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        wake.arguments = ["-u", "-t", "3"]
        do { try wake.run() } catch { log.record("shortcut_wake_failed", ["message": error.localizedDescription]) }

        log.record("shortcut_input", ["source": input.name, "value": input.ddc])
        controller.write("input", value: input.ddc) { result in
            guard self.request == current else { return }
            switch result {
            case .success:
                self.log.record("shortcut_confirmed", ["source": self.input.name])
                exit(0)
            case .failure(DDCOperationError.unconfirmed):
                self.log.record("shortcut_sent_unconfirmed", ["source": self.input.name])
                report("已发送切换到 \(self.input.name) 的命令", "切换后未能确认显示器回读，请以实际画面为准。", status: 2)
            case .failure:
                self.log.record("shortcut_failed", ["source": self.input.name])
                report("切换到 \(self.input.name) 失败", "请检查目标显示器与 Mac 的连接，确认 DDC/CI 已开启，然后重试。", status: 1)
            }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = ShortcutDelegate(input: input, serial: serial)
app.delegate = delegate
app.run()
