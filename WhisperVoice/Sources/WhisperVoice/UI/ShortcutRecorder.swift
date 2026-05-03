import Cocoa
import Carbon.HIToolbox

/// Clickable control that captures a key combo when focused. Replaces the
/// fixed-list dropdowns in the Shortcuts tab — user can bind any combo.
class ShortcutRecorderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var monitor: Any?

    var keyCode: UInt32
    var modifiers: UInt32
    var allowsBareKeys: Bool
    /// Fired after the user records a new combo so SwiftUI bindings update.
    var onChange: ((UInt32, UInt32) -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, allowsBareKeys: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.allowsBareKeys = allowsBareKeys
        super.init(frame: .zero)

        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateDisplay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        label.stringValue = "Press keys…"
        label.textColor = .secondaryLabelColor
        layer?.borderColor = NSColor.systemBlue.cgColor
        window?.makeFirstResponder(self)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            if Int(event.keyCode) == kVK_Escape {
                self.stopRecording()
                return nil
            }
            let mods = carbonModifiers(from: event.modifierFlags.rawValue)
            if !self.allowsBareKeys && mods == 0 {
                // Require a modifier: flash red briefly, keep recording.
                self.layer?.borderColor = NSColor.systemRed.cgColor
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.layer?.borderColor = NSColor.systemBlue.cgColor
                }
                return nil
            }
            self.keyCode = UInt32(event.keyCode)
            self.modifiers = mods
            self.onChange?(self.keyCode, self.modifiers)
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.textColor = .labelColor
        updateDisplay()
    }

    func updateDisplay() {
        let combo = modifiersToString(modifiers) + (modifiers != 0 ? " " : "") + keyCodeToString(keyCode)
        label.stringValue = combo
    }

    func setBinding(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        updateDisplay()
    }
}
