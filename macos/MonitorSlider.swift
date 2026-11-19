import AppKit
import SwiftUI

struct MonitorSlider: NSViewRepresentable {
    let title: String
    let value: Int?
    var onPreview: (Int?) -> Void = { _ in }
    let onCommit: (Int) -> Void

    func makeNSView(context: Context) -> MonitorSliderView {
        MonitorSliderView(frame: .zero)
    }

    func updateNSView(_ view: MonitorSliderView, context: Context) {
        view.onPreview = onPreview
        view.onCommit = onCommit
        view.setAccessibilityLabel(title)
        view.configure(value: value, enabled: context.environment.isEnabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MonitorSliderView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: 22)
    }
}

/// Draw every thumb explicitly, including in inactive menu-bar popovers.
final class MonitorSliderView: NSView, NSAccessibilitySlider {
    var onCommit: (Int) -> Void = { _ in }
    var onPreview: (Int?) -> Void = { _ in }
    private var value: Int?
    private var draft: Int?
    private var enabled = false
    private let radius: CGFloat = 6.5
    private let inset: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("Not used from a storyboard") }

    func configure(value: Int?, enabled: Bool) {
        self.value = value.map { min(100, max(0, $0)) }
        self.enabled = enabled && value != nil
        if !self.enabled, draft != nil { cancelOperation(nil) }
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { enabled }
    override func accessibilityValue() -> Any? { draft ?? value }
    override func accessibilityValueDescription() -> String? {
        (draft ?? value).map(String.init) ?? "尚未读取"
    }
    override func isAccessibilityEnabled() -> Bool { enabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let width = max(0, bounds.width - 2 * inset)
        let track = NSRect(x: bounds.minX + inset, y: bounds.midY - 2, width: width, height: 4)
        let position = CGFloat(draft ?? value ?? 0) / 100 * width
        NSColor(white: dark ? 0.35 : 0.76, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        if value != nil && position > 0 {
            var fill = track
            fill.size.width = position
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        }

        let thumb = NSRect(x: track.minX + position - radius, y: bounds.midY - radius,
                           width: 2 * radius, height: 2 * radius)
        let circle = NSBezierPath(ovalIn: thumb)
        NSColor(white: enabled ? 0.98 : (dark ? 0.67 : 0.87), alpha: 1).setFill()
        circle.fill()
        NSColor(white: dark ? 0.24 : 0.47, alpha: 1).setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }

    private func reading(_ event: NSEvent) -> Int {
        let x = convert(event.locationInWindow, from: nil).x - bounds.minX - inset
        return Int((min(1, max(0, x / max(1, bounds.width - 2 * inset))) * 100).rounded())
    }

    private func preview(_ reading: Int) {
        guard draft != reading else { return }
        draft = reading
        needsDisplay = true
        onPreview(reading)
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        window?.makeFirstResponder(self)
        preview(reading(event))
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, draft != nil else { return }
        preview(reading(event))
    }
    override func mouseUp(with event: NSEvent) {
        guard draft != nil else { return }
        let target = reading(event)
        cancelOperation(nil)
        commit(target)
    }
    override func cancelOperation(_ sender: Any?) {
        guard draft != nil else { return }
        draft = nil
        needsDisplay = true
        onPreview(nil)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelOperation(nil) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func commit(_ target: Int) {
        guard enabled, let current = value, current != target else { return }
        value = target
        needsDisplay = true
        onCommit(target)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func adjust(_ step: Int) -> Bool {
        guard enabled, let current = value else { return false }
        commit(min(100, max(0, current + step)))
        return true
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(1) }
    override func accessibilityPerformDecrement() -> Bool { adjust(-1) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: _ = adjust(-1)
        case 124, 126: _ = adjust(1)
        case 53 where draft != nil: cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }
}
