import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum PanelLayout {
    static let width: CGFloat = 390
    static let height: CGFloat = 840
    static let margin: CGFloat = 16
    static let menuWidth: CGFloat = 166

    @MainActor
    static func size(on screen: NSScreen?) -> CGSize {
        // The popover's arrow and outer frame sit outside its content rectangle.
        let available = screen.map { max(1, floor($0.visibleFrame.height) - 32) } ?? height
        return CGSize(width: width, height: min(height, available))
    }
}

private struct SettingsCard<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    let accessory: Accessory
    let content: Content

    init(title: String, symbol: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                accessory
            }
            .font(.system(size: 12, weight: .semibold))
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

private struct SliderSetting: View {
    let title: String
    let value: Int?
    let note: String
    let commit: (Int) -> Void

    @State private var draggedValue: Int?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Text((draggedValue ?? value).map(String.init) ?? "—")
                    .monospacedDigit()
                    .frame(width: 26, alignment: .trailing)
                Stepper(value: Binding(
                    get: { value ?? 0 },
                    set: { target in
                        if let value, target != value { commit(target) }
                    }
                ), in: 0...100) { Text(tr("微调%@", title)) }
                .labelsHidden()
                .controlSize(.small)
                .disabled(value == nil)
                .accessibilityValue(value.map(String.init) ?? tr("尚未读取"))
                .help(tr("%@每次调节 1", title))
            }
            MonitorSlider(title: title, value: value, onPreview: { draggedValue = $0 }, onCommit: commit)
        }
        .font(.system(size: 12))
    }
}

struct ControlPanel: View {
    @ObservedObject var store: DisplayStore

    private enum Page: Hashable { case control(ControlChannel), donation }

    private var page: Binding<Page> {
        Binding(get: { store.showingDonations ? .donation : .control(store.channel) }, set: { selection in
            switch selection {
            case .control(let channel): store.selectChannel(channel)
            case .donation: store.showingDonations = true
            }
        })
    }

    private var isDDC: Bool { store.channel == .ddc }
    private var currentInput: Int? {
        isDDC ? store.displayedDDC("input") : store.displayedBLE(.input)
    }
    private var inputNote: String {
        isDDC ? store.noteDDC("input") : store.noteBLE(.input)
    }
    var body: some View {
        VStack(spacing: 0) {
            header.fixedSize(horizontal: false, vertical: true)
            Divider()
            if store.showingDonations {
                DonationView()
            } else if store.needsBinding {
                ScrollView {
                    SettingsCard(title: tr("显示器"), symbol: "display") {
                        if !store.bindingOptions.isEmpty {
                            ForEach(store.bindingOptions, id: \.self) { identifier in
                                Button("GM001J · " + identifier) { store.chooseMonitor(identifier) }
                                    .buttonStyle(.link)
                            }
                        }
                        Button(tr("重新搜索")) { store.discoverMonitor() }
                            .disabled(store.discovering)
                        if store.selectingReplacement {
                            Button(tr("取消")) { store.endSelection() }
                        }
                    }
                    .padding(.horizontal, PanelLayout.margin)
                    .padding(.vertical, 12)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ViewThatFits(in: .vertical) {
                    settings.fixedSize(horizontal: false, vertical: true)
                    ScrollView(.vertical) { settings }
                        .scrollIndicators(.never)
                        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            Divider()
            footer.fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: PanelLayout.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputCard
            if isDDC {
                SettingsCard(title: tr("显示与声音"), symbol: "slider.horizontal.3") {
                    setting("luminance", title: tr("屏幕亮度"))
                    setting("contrast", title: tr("对比度"))
                    Divider()
                    setting("volume", title: tr("耳机音量"))
                    if store.ddcValues["luminance"] == nil {
                        hint(tr("等待读取亮度。若读取失败，请切回 Type-C 后刷新。"))
                    }
                }
            } else {
                SettingsCard(title: tr("画面"), symbol: "rectangle.on.rectangle") {
                    selector(.mode)
                    selector(.hdr)
                }
                SettingsCard(title: tr("氛围灯"), symbol: "lightbulb") {
                    selector(.lightPower, title: tr("灯光开关"))
                    selector(.lightEffect)
                    selector(.lightLevel)
                    if store.values[.lightEffect] == 7 {
                        selector(.frontColor)
                        selector(.rearColor)
                    } else if store.values[.lightEffect] != 6 {
                        selector(.lightColor)
                    }
                }
            }
            if !store.message.isEmpty { hint(store.message) }
        }
        .padding(.horizontal, PanelLayout.margin)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appTitle: some View {
        HStack(spacing: 9) {
            Image(systemName: "display")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.red)
                .frame(width: 32, height: 32)
                .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(tr("红魔显示器")).font(.system(size: 17, weight: .semibold))
        }
    }

    private var pagePicker: some View {
        Picker(tr("页面"), selection: page) {
            Text("DDC").tag(Page.control(.ddc))
            Text(tr("蓝牙")).tag(Page.control(.bluetooth))
            Text(tr("捐献")).tag(Page.donation)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    appTitle.fixedSize()
                    Spacer(minLength: 4)
                    pagePicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    appTitle
                    pagePicker
                }
            }
            if store.showingDonations {
                Text(tr("用对应的 App 扫码支持项目。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(height: 30)
            } else {
                connectionStatus
            }
        }
        .padding(.horizontal, PanelLayout.margin)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    private var connectionStatus: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 12, height: 12).overlay {
                if store.busy { ProgressView().controlSize(.mini) }
            }.accessibilityHidden(true)
            Text(store.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if !isDDC && !store.needsBinding {
                Button(store.bluetoothConnected ? tr("断开") : tr("连接并读取")) {
                    if store.bluetoothConnected { store.disconnectBluetooth() } else { store.refresh() }
                }
                .disabled(!store.bluetoothConnected && store.pendingBLE > 0)
                .help(tr("蓝牙空闲 5 分钟后自动断开"))
            }
            if !store.needsBinding {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(tr("刷新当前页面")).help(tr("重新读取当前通道的设置"))
            }
        }
        .controlSize(.small)
        .frame(minHeight: 30)
    }

    private var inputCard: some View {
        SettingsCard(title: isDDC ? tr("活动输入源") : tr("显示器菜单输入源"), symbol: "cable.connector", accessory: {
            Menu(tr("导出快捷方式…")) {
                ForEach(MonitorInput.ports, id: \.ddc) { port in
                    Button(port.name) { exportShortcut(for: port) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(tr("选择目标接口，导出独立运行的切源应用"))
        }) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                ForEach(isDDC ? DDCController.inputChoices : Feature.input.choices, id: \.0) { value, title in
                    let selected = currentInput == value
                    let confirmed = selected && inputNote.isEmpty
                    let inputIcon = selected ? "clock" : "display"
                    Button {
                        if isDDC { store.setDDC("input", value) } else { store.set(.input, value) }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: confirmed ? "checkmark.circle.fill" : inputIcon)
                                .foregroundStyle(confirmed ? Color.accentColor : .secondary)
                                .frame(width: 16)
                            Text(title).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(confirmed ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.055))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(confirmed ? [.isSelected] : [])
                    .accessibilityValue(selected ? inputNote : "")
                    .disabled(store.inputBusy)
                }
            }
            if !inputNote.isEmpty {
                let ports = isDDC ? DDCController.inputChoices : Feature.input.choices
                let name = ports.first(where: { $0.0 == currentInput })?.1
                hint([name, inputNote].compactMap { $0 }.joined(separator: " · "))
            }
            if let mismatch = store.inputMismatch {
                let action = isDDC ? tr("在蓝牙页选择") : tr("选择")
                hint(tr("活动输入为 %@，菜单为 %@。%@ %@ 可同步菜单。", mismatch.active, mismatch.menu, action, mismatch.active))
            } else if isDDC {
                hint(tr("切换输入时，会尝试通过已授权的蓝牙同步显示器菜单。"))
            } else {
                hint(tr("选择接口会同时切换画面和显示器菜单。"))
            }
        }
    }

    @MainActor
    private func exportShortcut(for port: MonitorInput) {
        Task { @MainActor in
            let initial = ShortcutExportTarget(serial: store.bindings.serial, address: store.bindings.address)
            do {
                guard !initial.serial.isEmpty || initial.address != nil else {
                    throw DisplayError(tr("请先识别显示器后再试。"))
                }
                let panel = NSSavePanel()
                panel.title = tr("导出快捷方式应用")
                let discovery = ShortcutExportDiscovery(target: initial)
                defer { discovery.cancel() }
                discovery.onMessage = { [weak panel] route in
                    panel?.message = tr("目标接口为 %@。%@", port.name, route)
                }
                panel.prompt = tr("导出")
                panel.allowedContentTypes = [.applicationBundle]
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                panel.nameFieldStringValue = tr("切换到%@.app", port.name)
                NSApp.activate()
                discovery.start()
                guard await panel.begin() == .OK, let destination = panel.url else { return }
                let replaceExisting = FileManager.default.fileExists(atPath: destination.path)
                let target = await discovery.targetForExport()
                try await Task.detached(priority: .userInitiated) {
                    try InputShortcutExporter.export(port: port, serial: target.serial, bluetoothAddress: target.address, to: destination,
                                                     replaceExisting: replaceExisting)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                let alert = NSAlert()
                alert.messageText = tr("无法导出快捷方式")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func setting(_ key: String, title: String) -> some View {
        SliderSetting(title: title, value: store.displayedDDC(key), note: store.noteDDC(key)) {
            store.setDDC(key, $0)
        }
    }

    private func selector(_ feature: Feature, title: String? = nil) -> some View {
        let label = title ?? feature.title
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12))
                let note = store.noteBLE(feature)
                if !note.isEmpty { hint(note) }
            }
            Spacer(minLength: 4)
            SettingDropdown(title: label, choices: feature.choices, selection: store.displayedBLE(feature)) {
                store.set(feature, $0)
            }
            .frame(width: PanelLayout.menuWidth, height: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var resetControls: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(store.isResettingDefaults ? tr("正在恢复…") : tr("恢复默认设置")) { store.resetDefaults() }
                .disabled(store.isResettingDefaults)
                .help(tr("通过 DDC 将亮度和对比度各设为 50"))
            Text(tr("亮度 50 · 对比度 50")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .opacity(store.showingDonations || store.needsBinding ? 0 : 1)
        .disabled(store.showingDonations || store.needsBinding)
        .accessibilityHidden(store.showingDonations || store.needsBinding)
    }

    private var appActions: some View {
        HStack(spacing: 10) {
            Toggle(tr("登录时启动"), isOn: Binding(get: { store.loginEnabled }, set: store.toggleLogin))
                .toggleStyle(.switch)
                .controlSize(.mini)
            Divider().frame(height: 14)
            Button(tr("日志")) { NSWorkspace.shared.open(store.log.directory) }
            Button(tr("退出")) { NSApplication.shared.terminate(nil) }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                resetControls.fixedSize()
                Spacer(minLength: 4)
                appActions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 7) {
                resetControls
                appActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, PanelLayout.margin)
        .padding(.vertical, 9)
    }
}
