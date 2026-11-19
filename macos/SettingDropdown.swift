import AppKit
import SwiftUI

/// A native pop-up whose bezel and arrow fill the proposed column width.
struct SettingDropdown: NSViewRepresentable {
    let title: String
    let choices: [(Int, String)]
    let selection: Int?
    let onSelect: (Int) -> Void

    final class Coordinator: NSObject {
        var choices: [(Int, String)] = []
        var onSelect: (Int) -> Void
        let placeholder = NSMenuItem(title: tr("选择设置"), action: nil, keyEquivalent: "")

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
            placeholder.isEnabled = false
        }

        @objc func picked(_ sender: NSPopUpButton) {
            guard let selected = sender.selectedItem, selected !== placeholder else { return }
            onSelect(selected.tag)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12)
        button.alignment = .left
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.autoenablesItems = false
        button.menu?.addItem(context.coordinator.placeholder)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        button.setAccessibilityLabel(title)
        if !choices.elementsEqual(coordinator.choices, by: { $0.0 == $1.0 && $0.1 == $1.1 }) {
            button.removeAllItems()
            button.menu?.addItem(coordinator.placeholder)
            for (value, label) in choices {
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.tag = value
                button.menu?.addItem(item)
            }
            coordinator.choices = choices
        }

        // The placeholder can have the same default tag as a valid zero setting.
        // Resolve by position in the ordered choices and exclude it from commands.
        let index = selection.flatMap { value in choices.firstIndex { $0.0 == value } }
        let menuIndex = index.map { $0 + 1 } ?? 0
        coordinator.placeholder.isHidden = index != nil
        if button.indexOfSelectedItem != menuIndex {
            button.selectItem(at: menuIndex)
        }
        button.isEnabled = context.environment.isEnabled && !choices.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width,
                      height: proposal.height ?? intrinsic.height)
    }
}
