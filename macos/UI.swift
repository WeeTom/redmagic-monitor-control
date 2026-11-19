import SwiftUI
import AppKit

enum PanelLayout {
    static let margin: CGFloat = 16
    static let menuWidth: CGFloat = 166

    static func size(for channel: ControlChannel) -> CGSize {
        CGSize(width: 390, height: channel == .ddc ? 540 : 600)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title).accessibilityAddTraits(.isHeader)
            }
            .font(.system(size: 12, weight: .semibold))
            content()
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
                ), in: 0...100) { Text("微调" + title) }
                .labelsHidden()
                .controlSize(.small)
                .disabled(value == nil)
                .accessibilityValue(value.map(String.init) ?? "尚未读取")
                .help(title + "每次调节 1")
            }
            MonitorSlider(title: title, value: value, onPreview: { draggedValue = $0 }, onCommit: commit)
        }
        .font(.system(size: 12))
    }
}

struct ControlPanel: View {
    @ObservedObject var store: DisplayStore

    private var isDDC: Bool { store.channel == .ddc }
    private var currentInput: Int? {
        isDDC ? store.displayedDDC("input") : store.displayedBLE(.input)
    }
    var body: some View {
        let size = PanelLayout.size(for: store.channel)
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    inputCard
                    if isDDC {
                        SettingsCard(title: "显示与声音", symbol: "slider.horizontal.3") {
                            setting("luminance", title: "屏幕亮度")
                            setting("contrast", title: "对比度")
                            Divider()
                            setting("volume", title: "耳机音量")
                            if store.ddcValues["luminance"] == nil {
                                hint("等待读取亮度。若读取失败，请切回 Type-C 后刷新。")
                            }
                        }
                    } else {
                        SettingsCard(title: "画面", symbol: "rectangle.on.rectangle") {
                            selector(.mode)
                            selector(.hdr)
                        }
                        SettingsCard(title: "氛围灯", symbol: "lightbulb") {
                            selector(.lightPower, title: "灯光开关")
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
            Divider()
            footer
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "display")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                Text("红魔显示器").font(.system(size: 17, weight: .semibold))
                Spacer()
                Picker("控制通道", selection: Binding(get: { store.channel }, set: store.selectChannel)) {
                    Text("DDC").tag(ControlChannel.ddc)
                    Text("蓝牙").tag(ControlChannel.bluetooth)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            HStack(spacing: 6) {
                if store.busy {
                    ProgressView().controlSize(.mini).frame(width: 12)
                }
                Text(store.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if !isDDC {
                    Button(store.bluetoothConnected ? "断开" : "连接并读取") {
                        if store.bluetoothConnected { store.disconnectBluetooth() } else { store.refresh() }
                    }
                    .disabled(!store.bluetoothConnected && store.pendingBLE > 0)
                    .help("蓝牙空闲 5 分钟后自动断开")
                }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新当前页面").help("重新读取当前通道的设置")
            }
            .controlSize(.small)
            .frame(minHeight: 20)
        }
        .padding(.horizontal, PanelLayout.margin)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    private var inputCard: some View {
        SettingsCard(title: "输入源", symbol: "cable.connector") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                ForEach(isDDC ? DDCController.inputChoices : Feature.input.choices, id: \.0) { value, title in
                    let selected = currentInput == value
                    Button {
                        if isDDC { store.setDDC("input", value) } else { store.set(.input, value) }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: selected ? (store.inputBusy ? "clock" : "checkmark.circle.fill") : "display")
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                                .frame(width: 16)
                            Text(title).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.055))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .disabled(store.inputBusy)
                }
            }
            let note = isDDC ? store.noteDDC("input") : store.noteBLE(.input)
            if !note.isEmpty { hint(note) }
            if isDDC { hint("需要同步显示器菜单时，请用蓝牙切换。") }
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

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Button(store.isResettingDefaults ? "正在恢复…" : "恢复默认设置") { store.resetDefaults() }
                    .disabled(store.isResettingDefaults)
                    .help("通过 DDC 将亮度和对比度各设为 50")
                Text("亮度 50 · 对比度 50").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("登录时启动", isOn: Binding(get: { store.loginEnabled }, set: store.toggleLogin))
                .toggleStyle(.switch)
                .controlSize(.mini)
            Divider().frame(height: 14)
            Button("日志") { NSWorkspace.shared.open(store.log.directory) }
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, PanelLayout.margin)
        .padding(.vertical, 9)
    }
}
