import Foundation

enum ShortcutOutcome {
    case confirmed(String)
    case failed(String)
    case unconfirmed(String)
}

// Preserve the distinction between a command that never left the Mac and a
// command that may have switched away its own DDC connection.
struct ShortcutSwitch {
    typealias Reply = (Result<Int, Error>) -> Void
    let input: MonitorInput
    let sendDDC: ((Int, @escaping Reply) -> Void)?
    let submitBLE: ((Int?, @escaping Reply) -> Void)?
    let bleHasSent: () -> Bool
    let current: () -> Bool
    let finish: (ShortcutOutcome) -> Void

    func start() {
        guard current() else { return }
        guard let sendDDC else { fallback(ddcSent: false); return }
        sendDDC(input.ddc) { result in
            guard current() else { return }
            switch result {
            case .success(let value) where value == input.ddc:
                finish(.confirmed("DDC"))
            case .failure(DDCOperationError.unavailable):
                fallback(ddcSent: false)
            case .failure(DDCOperationError.superseded):
                return
            default:
                fallback(ddcSent: true)
            }
        }
    }

    private func fallback(ddcSent: Bool) {
        guard submitBLE != nil else {
            finish(ddcSent
                ? .unconfirmed(tr("DDC 已发送切换命令，显示器未确认回读。"))
                : .failed(tr("无法通过 DDC 连接目标显示器。此快捷方式未绑定蓝牙地址。")))
            return
        }
        if ddcSent { verifyExisting(matches: 0) }
        else { setBluetooth(ddcSent: false) }
    }

    private func verifyExisting(matches: Int) {
        submitBLE?(nil) { result in
            guard current() else { return }
            switch result {
            case .success(let value) where value != input.bluetooth:
                setBluetooth(ddcSent: true)
            case .success where matches == 1:
                finish(.confirmed(tr("蓝牙菜单（活动画面未独立验证）")))
            case .success:
                verifyExisting(matches: 1)
            case .failure(let error):
                failBluetooth(error, ddcSent: true)
            }
        }
    }

    private func setBluetooth(ddcSent: Bool) {
        // An explicit set performs its own preflight, then verifies two fresh replies.
        submitBLE?(input.bluetooth) { result in
            guard current() else { return }
            switch result {
            case .success(let value) where value == input.bluetooth:
                finish(.confirmed(tr("蓝牙")))
            case .success:
                finish(.unconfirmed(tr("蓝牙回读与目标输入源不符，请检查实际画面。")))
            case .failure(let error):
                failBluetooth(error, ddcSent: ddcSent)
            }
        }
    }

    private func failBluetooth(_ error: Error, ddcSent: Bool) {
        let detail = error.localizedDescription
        if ddcSent || bleHasSent() {
            finish(.unconfirmed(tr("切换命令已发送。蓝牙未能确认目标输入源。%@", detail)))
        } else {
            finish(.failed(tr("无法通过蓝牙切换。%@", detail)))
        }
    }
}
