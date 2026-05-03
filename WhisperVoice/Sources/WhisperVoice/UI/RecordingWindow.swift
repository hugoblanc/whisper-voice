import Cocoa

// MARK: - Mode Selector View

extension Notification.Name {
    /// Fired when the selected mode changes so the parent repositions the
    /// "⇧ switch" hint that sits to the right of the selector.
    static let modeSelectorLayoutChanged = Notification.Name("com.whisper-voice.modeSelectorLayoutChanged")
}

class ModeSelectorView: NSView {
    private var modeViews: [NSView] = []
    private var modeLabels: [NSTextField] = []

    var onModeChanged: ((Int) -> Void)?

    /// Computed trailing edge of the last mode cell. Used by the parent window
    /// to lay out the "⇧ switch" hint outside the selector so it doesn't look
    /// like another (disabled) mode.
    private(set) var modesTrailingX: CGFloat = 0

    private let expandedWidth: CGFloat = 90
    private let collapsedWidth: CGFloat = 32
    private let itemHeight: CGFloat = 28
    private let spacing: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let modes = ModeManager.shared.modes
        var xOffset: CGFloat = 8

        for (index, mode) in modes.enumerated() {
            let isSelected = index == ModeManager.shared.currentModeIndex
            let isAvailable = ModeManager.shared.isModeAvailable(at: index)
            let width = isSelected ? expandedWidth : collapsedWidth

            // Container for each mode
            let container = NSView(frame: NSRect(x: xOffset, y: 4, width: width, height: itemHeight))
            container.wantsLayer = true
            container.layer?.cornerRadius = 8
            container.alphaValue = isAvailable ? 1.0 : 0.35

            if isSelected && isAvailable {
                // Active state — translucent white fill instead of full accent
                // to keep the HUD aesthetic tonal (matches Cancel/Stop buttons).
                container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
                container.layer?.borderWidth = 0.5
                container.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            }

            // Icon
            let iconSize: CGFloat = 16
            let iconX: CGFloat = isSelected ? 8 : (width - iconSize) / 2
            let iconView = NSImageView(frame: NSRect(x: iconX, y: (itemHeight - iconSize) / 2, width: iconSize, height: iconSize))
            if let image = NSImage(systemSymbolName: mode.icon, accessibilityDescription: mode.name) {
                iconView.image = image
                iconView.contentTintColor = isSelected && isAvailable ? .white : .white.withAlphaComponent(0.6)
            }
            container.addSubview(iconView)

            // Label (only for selected)
            let label = NSTextField(labelWithString: mode.name)
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
            label.frame = NSRect(x: 28, y: (itemHeight - 14) / 2, width: 60, height: 14)
            label.alphaValue = isSelected ? 1 : 0
            container.addSubview(label)
            modeLabels.append(label)

            addSubview(container)
            modeViews.append(container)

            xOffset += width + spacing
        }

        // Trailing edge of the last mode cell — parent window places the
        // "⇧ switch" hint to the right of this, OUTSIDE our rounded container,
        // so it doesn't look like another (disabled) mode.
        modesTrailingX = xOffset
        var f = frame
        f.size.width = xOffset + 4
        frame = f
    }

    func updateSelection(animated: Bool = true) {
        let selectedIndex = ModeManager.shared.currentModeIndex

        var xOffset: CGFloat = 8

        let updateBlock = {
            for (index, container) in self.modeViews.enumerated() {
                let isSelected = index == selectedIndex
                let isAvailable = ModeManager.shared.isModeAvailable(at: index)
                let width = isSelected ? self.expandedWidth : self.collapsedWidth

                container.frame = NSRect(x: xOffset, y: 4, width: width, height: self.itemHeight)
                container.alphaValue = isAvailable ? 1.0 : 0.35
                container.layer?.backgroundColor = isSelected && isAvailable
                    ? NSColor.white.withAlphaComponent(0.24).cgColor
                    : NSColor.clear.cgColor
                container.layer?.borderWidth = 0

                // Update icon position and color
                if let iconView = container.subviews.first as? NSImageView {
                    let iconX: CGFloat = isSelected ? 8 : (width - 16) / 2
                    iconView.frame.origin.x = iconX
                    iconView.contentTintColor = isSelected && isAvailable ? .white : .white.withAlphaComponent(0.55)
                }

                // Update label visibility
                self.modeLabels[index].alphaValue = isSelected ? 1 : 0

                xOffset += width + self.spacing
            }

            self.modesTrailingX = xOffset
            // Let the parent reposition its own hint relative to us.
            NotificationCenter.default.post(name: .modeSelectorLayoutChanged, object: self)
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                updateBlock()
            }
        } else {
            updateBlock()
        }

        onModeChanged?(selectedIndex)
    }

    func cycleMode() {
        _ = ModeManager.shared.nextMode()
        updateSelection(animated: true)
    }
}

// MARK: - Waveform View

class WaveformView: NSView {
    private var levels: [CGFloat] = Array(repeating: 0, count: 48)
    private var currentIndex = 0
    private var smoothedLevels: [CGFloat] = Array(repeating: 0, count: 48)

    var baseColor: NSColor = NSColor.systemRed
    var accentColor: NSColor = NSColor.systemOrange

    func addLevel(_ level: Float) {
        levels[currentIndex] = CGFloat(level)

        // Smooth the levels for nicer animation
        for i in 0..<smoothedLevels.count {
            let target = levels[i]
            let current = smoothedLevels[i]
            // Fast rise, slow fall for natural look
            if target > current {
                smoothedLevels[i] = current + (target - current) * 0.6
            } else {
                smoothedLevels[i] = current + (target - current) * 0.12
            }
        }

        currentIndex = (currentIndex + 1) % levels.count
        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: 0, count: levels.count)
        smoothedLevels = Array(repeating: 0, count: smoothedLevels.count)
        currentIndex = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Background
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(bounds)

        // Draw bars - sleek design
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 3
        let totalBarWidth = barWidth + barSpacing
        let numBars = smoothedLevels.count
        let startX = (bounds.width - CGFloat(numBars) * totalBarWidth) / 2
        let minHeight: CGFloat = 4
        let maxHeight = bounds.height

        for i in 0..<numBars {
            let displayIndex = (currentIndex + i) % numBars
            let level = smoothedLevels[displayIndex]

            // More dramatic height variation with curve
            let boostedLevel = pow(level, 0.6)  // Boost low levels for visibility
            let barHeight = max(minHeight, boostedLevel * maxHeight)
            let x = startX + CGFloat(i) * totalBarWidth
            let y = (bounds.height - barHeight) / 2

            let barRect = NSRect(x: x, y: y, width: barWidth, height: barHeight)

            // Gradient color based on level - red to orange to yellow for peaks
            let color: NSColor
            if level > 0.7 {
                // Peak - bright orange/yellow
                color = NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)
            } else if level > 0.4 {
                // Medium-high - orange blend
                let t = (level - 0.4) / 0.3
                color = NSColor(
                    red: 0.9 + 0.1 * t,
                    green: 0.3 + 0.3 * t,
                    blue: 0.2,
                    alpha: 1.0
                )
            } else {
                // Low to medium - base red
                color = baseColor
            }

            // Subtle glow for high levels
            if level > 0.5 {
                let glowRect = barRect.insetBy(dx: -1.5, dy: -1.5)
                let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: (barWidth + 3) / 2, yRadius: (barWidth + 3) / 2)
                color.withAlphaComponent(0.25).setFill()
                glowPath.fill()
            }

            // Main bar with rounded caps
            let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            color.setFill()
            path.fill()
        }
    }
}

// MARK: - Recording Window

// MARK: - Capsule action button

/// Pill-shaped, translucent action button that plays nicer with the glass
/// RecordingWindow background than NSButton(bezelStyle: .rounded).
/// - Translucent fill + 1px stroke + optional accent-tinted primary variant.
/// - Hover lifts the fill slightly; mouseDown taps it darker.
/// - Ties into the window's default/escape key equivalents via keyEquivalent.
final class CapsuleButton: NSView {
    var onClick: (() -> Void)?
    /// Matching NSButton semantics so \r / Esc still close the panel.
    var keyEquivalent: String = ""

    private let titleField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var isPrimary: Bool
    private var isDestructive: Bool
    private var isHovering: Bool = false { didSet { refreshStyle() } }
    private var isPressed: Bool = false { didSet { refreshStyle() } }

    init(title: String, symbol: String? = nil, isPrimary: Bool = false, isDestructive: Bool = false) {
        self.isPrimary = isPrimary
        self.isDestructive = isDestructive
        super.init(frame: .zero)
        wantsLayer = true

        titleField.stringValue = title
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = isPrimary ? .white : NSColor.white.withAlphaComponent(0.9)
        titleField.alignment = .center
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleField)

        if let symbol = symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            iconView.image = image
            iconView.contentTintColor = titleField.textColor
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 13),
                iconView.heightAnchor.constraint(equalToConstant: 13),
                titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
                titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        refreshStyle()
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2   // fully pill
    }

    private func refreshStyle() {
        layer?.borderWidth = 1
        // Both variants stay tonal / translucent — no accent-color wash, which
        // fights the HUD glass aesthetic. Primary = brighter fill + stronger edge.
        if isPrimary {
            let fill = isPressed ? 0.32 : (isHovering ? 0.26 : 0.20)
            layer?.backgroundColor = NSColor.white.withAlphaComponent(CGFloat(fill)).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            titleField.textColor = .white
            iconView.contentTintColor = .white
        } else if isDestructive {
            let base = NSColor.systemRed
            layer?.backgroundColor = base.withAlphaComponent(isPressed ? 0.35 : (isHovering ? 0.25 : 0.15)).cgColor
            layer?.borderColor = base.withAlphaComponent(0.5).cgColor
        } else {
            let fill = isPressed ? 0.14 : (isHovering ? 0.10 : 0.06)
            layer?.backgroundColor = NSColor.white.withAlphaComponent(CGFloat(fill)).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            titleField.textColor = NSColor.white.withAlphaComponent(0.88)
            iconView.contentTintColor = NSColor.white.withAlphaComponent(0.88)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    /// Let the window's key event machinery trigger us via Return / Escape.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !keyEquivalent.isEmpty, event.charactersIgnoringModifiers == keyEquivalent {
            onClick?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Recording Window

class RecordingWindow: NSObject {
    private var window: NSPanel!
    private var waveformView: WaveformView!
    private var statusDot: NSView!
    private var statusDotHalo: NSView!  // Larger sibling that pulses with audio — placed behind statusDot
    private var statusLabel: NSTextField!
    private var timerLabel: NSTextField!
    private var cancelCapsuleButton: CapsuleButton?
    private var stopCapsuleButton: CapsuleButton?
    private var modeSelector: ModeSelectorView!
    private var projectChip: ProjectChipView!
    private var autoModeLabel: NSTextField!
    private var modeSwitchHint: NSTextField!
    private var projectPicker: NSPopover?

    /// Called when user picks a different project (or nil = untag) for the
    /// current recording. AppDelegate uses this to update its pending tag.
    var onProjectChanged: ((Project?, String) -> Void)?

    private var updateTimer: Timer?
    private var recordingStartTime: Date?

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var audioLevelProvider: (() -> Float)?
    var onModeChanged: ((ProcessingMode) -> Void)?

    enum RecordingStatus {
        case recording
        case processing
        case completed
    }

    override init() {
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        // Floating panel — Liquid-Glass-style: transparent chrome + NSVisualEffectView
        // fills the content rect to let wallpaper / apps bleed through (like Control
        // Center). Falls back gracefully on older macOS versions since material types
        // are available since 10.14.
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 234),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 20
        contentView.layer?.masksToBounds = true

        // Translucent material base — the "glass" layer. `.fullScreenUI` gives
        // a heavier blur closer to the native volume/brightness HUD on Tahoe
        // than `.hudWindow`. `.behindWindow` lets the desktop / apps bleed through.
        let effect = NSVisualEffectView(frame: contentView.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true
        contentView.addSubview(effect, positioned: .below, relativeTo: nil)

        // Very light darkening just so white text stays readable on bright
        // wallpapers — 0.18 instead of 0.55 previously (was killing translucency).
        let tint = NSView(frame: contentView.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.18).cgColor
        contentView.addSubview(tint, positioned: .above, relativeTo: effect)

        // Glass highlight: brighter 1px stroke + subtle inner glow layer for
        // refraction feel — much closer to macOS Tahoe's native HUDs.
        let highlight = CAShapeLayer()
        let strokeRect = contentView.bounds.insetBy(dx: 0.5, dy: 0.5)
        highlight.frame = contentView.bounds
        highlight.path = CGPath(roundedRect: strokeRect, cornerWidth: 21.5, cornerHeight: 21.5, transform: nil)
        highlight.lineWidth = 1
        highlight.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        highlight.fillColor = NSColor.clear.cgColor
        contentView.layer?.addSublayer(highlight)

        // Waveform view at top (below title bar area)
        waveformView = WaveformView(frame: NSRect(x: 16, y: 174, width: 328, height: 45))
        contentView.addSubview(waveformView)

        // Status row: dot + label + timer
        // Halo is a sibling of the dot (not a sublayer) so it isn't clipped by
        // the dot's corner-radius masking. Kept small (18x18) and subtle —
        // earlier iterations at 28x28 felt bloated relative to the 10px dot.
        statusDotHalo = NSView(frame: NSRect(x: 12, y: 146, width: 18, height: 18))
        statusDotHalo.wantsLayer = true
        statusDotHalo.layer?.cornerRadius = 9
        statusDotHalo.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.45).cgColor
        statusDotHalo.alphaValue = 0
        contentView.addSubview(statusDotHalo)

        statusDot = NSView(frame: NSRect(x: 16, y: 150, width: 10, height: 10))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
        contentView.addSubview(statusDot)

        statusLabel = NSTextField(labelWithString: "Recording")
        statusLabel.frame = NSRect(x: 32, y: 147, width: 120, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .white
        contentView.addSubview(statusLabel)

        timerLabel = NSTextField(labelWithString: "0:00")
        timerLabel.frame = NSRect(x: 290, y: 147, width: 55, height: 18)
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timerLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        timerLabel.alignment = .right
        contentView.addSubview(timerLabel)

        // Mode selector — container width now matches the modes only. The
        // "⇧ switch" hint is a separate sibling label (modeSwitchHint)
        // positioned to the right, so it doesn't look like a disabled mode.
        modeSelector = ModeSelectorView(frame: NSRect(x: 12, y: 106, width: 260, height: 36))
        modeSelector.onModeChanged = { [weak self] index in
            let mode = ModeManager.shared.modes[index]
            self?.onModeChanged?(mode)
        }
        contentView.addSubview(modeSelector)

        modeSwitchHint = NSTextField(labelWithString: "")
        modeSwitchHint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        modeSwitchHint.textColor = NSColor.white.withAlphaComponent(0.38)
        modeSwitchHint.frame = NSRect(x: 0, y: 114, width: 90, height: 14)
        contentView.addSubview(modeSwitchHint)
        refreshModeSwitchHint()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleModeSelectorLayoutChanged),
            name: .modeSelectorLayoutChanged, object: nil
        )

        // Auto-mode reason label (muted, hidden unless auto-selection kicked in)
        autoModeLabel = NSTextField(labelWithString: "")
        autoModeLabel.frame = NSRect(x: 16, y: 84, width: 328, height: 16)
        autoModeLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        autoModeLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        autoModeLabel.alignment = .center
        autoModeLabel.isHidden = true
        contentView.addSubview(autoModeLabel)

        // Project chip — between mode selector and action buttons
        projectChip = ProjectChipView(frame: NSRect(x: 12, y: 48, width: 336, height: 30))
        projectChip.onClick = { [weak self] in self?.showProjectPicker() }
        contentView.addSubview(projectChip)

        // Capsule action buttons — custom views for a pill shape and translucent fill
        // that play nicer with the glass background than NSButton(bezelStyle: .rounded).
        let cancelCapsule = CapsuleButton(title: "Cancel", symbol: "xmark", isDestructive: false)
        cancelCapsule.frame = NSRect(x: 16, y: 10, width: 96, height: 32)
        cancelCapsule.onClick = { [weak self] in self?.cancelClicked() }
        cancelCapsule.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelCapsule)

        let stopCapsule = CapsuleButton(title: "Stop", symbol: "stop.fill", isPrimary: true)
        stopCapsule.frame = NSRect(x: 248, y: 10, width: 96, height: 32)
        stopCapsule.onClick = { [weak self] in self?.stopClicked() }
        stopCapsule.keyEquivalent = "\r"
        contentView.addSubview(stopCapsule)

        self.cancelCapsuleButton = cancelCapsule
        self.stopCapsuleButton = stopCapsule
    }

    func show() {
        recordingStartTime = Date()
        waveformView.reset()
        modeSelector.updateSelection(animated: false)
        autoModeLabel.stringValue = ""
        autoModeLabel.isHidden = true
        setStatus(.recording)

        // Position at top center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - window.frame.width / 2
            let y = screenFrame.maxY - window.frame.height - 50
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.orderFront(nil)

        // Start update timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateWaveform()
        }

        // Play start sound
        playSound(named: "Tink")
    }

    func hide() {
        updateTimer?.invalidate()
        updateTimer = nil
        window.orderOut(nil)
    }

    func setStatus(_ status: RecordingStatus) {
        switch status {
        case .recording:
            statusDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            statusLabel.stringValue = "Recording"
            waveformView.baseColor = NSColor.systemRed
            waveformView.accentColor = NSColor.systemOrange
            startPulsingDot()
        case .processing:
            statusDot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            let mode = ModeManager.shared.currentMode
            statusLabel.stringValue = mode.requiresProcessing ? "Processing (\(mode.name))..." : "Transcribing..."
            waveformView.baseColor = NSColor.systemBlue
            waveformView.accentColor = NSColor.systemCyan
            stopPulsingDot()
        case .completed:
            statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusLabel.stringValue = "Done"
            waveformView.baseColor = NSColor.systemGreen
            waveformView.accentColor = NSColor.systemGreen
            stopPulsingDot()
            // Play completion sound
            playSound(named: "Glass")
        }
    }

    func cycleMode() {
        modeSelector.cycleMode()
    }

    /// Re-highlight the currently active mode (e.g. after auto-mode switched it externally).
    func updateModeSelection() {
        modeSelector?.updateSelection(animated: true)
    }

    private func updateWaveform() {
        // Update waveform with current audio level
        if let level = audioLevelProvider?() {
            waveformView.addLevel(level)
            // Drive the halo glow around the status dot with the same audio level —
            // gives a "breathing, alive" feel that reacts to speech.
            updateStatusDotHalo(level: level)
        }

        // Update timer
        if let startTime = recordingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            timerLabel.stringValue = String(format: "%d:%02d", minutes, seconds)
        }
    }

    private var pulseTimer: Timer?
    private var haloLevel: Float = 0
    private var haloActive: Bool = false

    /// Smoothed alpha + subtle scale modulation of the halo based on input audio.
    /// Kept very subtle — max ~1.2x scale and 0.7 alpha so it never dominates.
    private func updateStatusDotHalo(level: Float) {
        guard haloActive, let halo = statusDotHalo, let layer = halo.layer else { return }
        haloLevel = haloLevel * 0.55 + max(0, min(1, level)) * 0.45
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.alphaValue = CGFloat(0.1 + haloLevel * 0.6)
        let scale = CGFloat(1.0 + haloLevel * 0.22)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    private func startPulsingDot() {
        haloActive = true
        // Baseline slow heartbeat whenever audio is silent so the dot keeps
        // signalling "recording" even during speech pauses.
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { [weak self] _ in
            guard let self = self, self.haloActive, self.haloLevel < 0.08 else { return }
            guard let halo = self.statusDotHalo, let layer = halo.layer else { return }
            let alphaAnim = CABasicAnimation(keyPath: "opacity")
            alphaAnim.fromValue = 0.15
            alphaAnim.toValue = 0.55
            alphaAnim.duration = 0.55
            alphaAnim.autoreverses = true
            alphaAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(alphaAnim, forKey: "idlePulseOpacity")
        }
    }

    private func stopPulsingDot() {
        haloActive = false
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusDot.alphaValue = 1.0
        statusDotHalo?.layer?.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statusDotHalo?.alphaValue = 0
        statusDotHalo?.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        haloLevel = 0
    }

    private func playSound(named name: String) {
        NSSound(named: name)?.play()
    }

    /// Position the "⇧ switch" hint relative to the selector's trailing edge.
    @objc private func handleModeSelectorLayoutChanged() {
        refreshModeSwitchHint()
    }

    private func refreshModeSwitchHint() {
        guard let selector = modeSelector, let hint = modeSwitchHint else { return }
        let hasOpenAI = ModeManager.shared.hasOpenAIKey
        let hintText = hasOpenAI ? "⇧ switch" : "⇧ (need OpenAI key)"
        hint.stringValue = hintText
        hint.textColor = hasOpenAI ? NSColor.white.withAlphaComponent(0.38) : NSColor.systemOrange.withAlphaComponent(0.7)
        hint.sizeToFit()

        // Trailing edge of the selector (in our content coords) + gap.
        let hintX = selector.frame.minX + selector.modesTrailingX + 16
        let y = selector.frame.minY + (selector.frame.height - hint.frame.height) / 2
        hint.frame.origin = NSPoint(x: hintX, y: y)
    }

    @objc private func stopClicked() {
        hide()
        onStop?()
    }

    @objc private func cancelClicked() {
        hide()
        onCancel?()
    }

    // MARK: - Project tagging

    func setProject(_ project: Project?, reason: String, confidence: Double) {
        projectChip?.set(project: project, reason: reason, confidence: confidence)
    }

    /// Update (or clear) the "auto: Mode (App)" label below the mode selector.
    /// Pass nil to hide it (e.g. user Shift-cycles = override).
    func setAutoModeReason(_ reason: String?) {
        guard let autoModeLabel = autoModeLabel else { return }
        if let reason = reason, !reason.isEmpty {
            autoModeLabel.stringValue = reason
            autoModeLabel.isHidden = false
        } else {
            autoModeLabel.stringValue = ""
            autoModeLabel.isHidden = true
        }
    }

    private func showProjectPicker() {
        guard let chip = projectChip else { return }
        let picker = ProjectPickerViewController(
            current: chip.currentProject,
            onPick: { [weak self] project, source in
                self?.projectPicker?.performClose(nil)
                self?.projectPicker = nil
                let reason = project == nil ? "cleared" : "manual"
                self?.projectChip?.set(project: project, reason: reason, confidence: 1.0)
                self?.onProjectChanged?(project, source)
            }
        )
        let popover = NSPopover()
        popover.contentViewController = picker
        popover.behavior = .transient
        popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: .maxY)
        projectPicker = popover
    }
}

// MARK: - Project chip + picker

/// Small pill shown inside RecordingWindow. Click opens the picker popover.
class ProjectChipView: NSView {
    private(set) var currentProject: Project?
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        set(project: nil, reason: "no-signal", confidence: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.16).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func set(project: Project?, reason: String, confidence: Double) {
        currentProject = project
        let muted = NSColor.white.withAlphaComponent(0.5)
        let primary = NSColor.white
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: "in: ", attributes: [.foregroundColor: muted]))
        if let project = project {
            let dotColor = project.color.flatMap { NSColor.fromHex($0) } ?? NSColor.systemGreen
            attr.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dotColor]))
            attr.append(NSAttributedString(string: project.name, attributes: [.foregroundColor: primary]))
            if confidence > 0 && reason != "manual" && reason != "cleared" {
                let hint = reason == "last-used" ? "   (last-used)" : "   \(Int(confidence * 100))%"
                attr.append(NSAttributedString(string: hint, attributes: [.foregroundColor: muted, .font: NSFont.systemFont(ofSize: 11)]))
            }
        } else {
            attr.append(NSAttributedString(string: "(untagged)   click to pick", attributes: [.foregroundColor: muted]))
        }
        label.attributedStringValue = attr
    }
}

/// Floating picker. NSTableView of active projects + search field that doubles
/// as "Create new…" input (⏎ creates when name is new). "Untag" button clears.
class ProjectPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let current: Project?
    private let onPick: (Project?, String) -> Void

    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let untagButton = NSButton(title: "Untag", target: nil, action: nil)
    private var filtered: [Project] = []

    init(current: Project?, onPick: @escaping (Project?, String) -> Void) {
        self.current = current
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 320))

        searchField.placeholderString = "Filter or type to create…"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchEnter)
        searchField.frame = NSRect(x: 10, y: 280, width: 260, height: 24)
        root.addSubview(searchField)

        let scroll = NSScrollView(frame: NSRect(x: 10, y: 46, width: 260, height: 228))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView.headerView = nil
        tableView.rowSizeStyle = .small
        tableView.dataSource = self
        tableView.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        col.width = 240
        tableView.addTableColumn(col)
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        scroll.documentView = tableView
        root.addSubview(scroll)

        untagButton.target = self
        untagButton.action = #selector(untagClicked)
        untagButton.bezelStyle = .rounded
        untagButton.frame = NSRect(x: 10, y: 10, width: 80, height: 28)
        root.addSubview(untagButton)

        let createLabel = NSTextField(labelWithString: "⏎ creates if name is new")
        createLabel.textColor = .secondaryLabelColor
        createLabel.font = NSFont.systemFont(ofSize: 10)
        createLabel.frame = NSRect(x: 100, y: 14, width: 170, height: 20)
        root.addSubview(createLabel)

        self.view = root
        refreshList()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.searchField)
        }
    }

    private func refreshList() {
        let query = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        let all = ProjectStore.shared.active
        if query.isEmpty { filtered = all } else { filtered = all.filter { $0.name.lowercased().contains(query) } }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tv: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: filtered[row].name)
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if filtered[row].id == current?.id {
            tf.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        }
        return cell
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filtered.count else { return }
        onPick(filtered[row], "manual")
    }

    @objc private func untagClicked() {
        onPick(nil, "manual")
    }

    @objc private func searchEnter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return }
        if let existing = ProjectStore.shared.byName(query) {
            onPick(existing, "manual")
        } else {
            let created = ProjectStore.shared.create(name: query)
            onPick(created, "manual")
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshList()
    }
}
