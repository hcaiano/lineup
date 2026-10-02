import AppKit
import DisplayControlCore

/// Confirmed keyboard levels use the system OSD on the display receiving the command.
/// A non-activating native-material HUD handles errors and an unavailable system OSD service.
@MainActor
final class DisplayControlHUD {
    struct Feedback {
        let monitorName: String
        let control: DisplayControl
        let level: DisplayControlLevel?
        var isPending = false
        var error: String?
        var isBlackedOut = false
    }

    static let size = NSSize(width: 304, height: 108)

    private var panel: DisplayControlHUDPanel?
    private var dismissal: Timer?
    private var generation = 0
    private let nativeOSD = NativeDisplayOSD()

    func show(_ feedback: Feedback, on screen: NSScreen?) {
        guard let screen else { hide(); return }
        generation += 1
        let shownGeneration = generation
        // Pending requests are not hardware readings. Wait for readback before showing a level.
        if feedback.isPending, feedback.error == nil, !feedback.isBlackedOut { return }
        if feedback.isBlackedOut,
           let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            dismissal?.invalidate()
            dismissal = nil
            panel?.orderOut(nil)
            if nativeOSD.showBlackScreen(displayID: displayID, onFailure: { [weak self] in
                guard let self, self.generation == shownGeneration else { return }
                self.showFallback(feedback, on: screen)
            }) { return }
            showFallback(feedback, on: screen)
            return
        }
        if feedback.error == nil, let level = feedback.level,
           let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            dismissal?.invalidate()
            dismissal = nil
            panel?.orderOut(nil)
            if nativeOSD.show(control: feedback.control, level: level, displayID: displayID,
                              onFailure: { [weak self] in
                guard let self, self.generation == shownGeneration else { return }
                self.showFallback(feedback, on: screen)
            }) { return }
        }
        showFallback(feedback, on: screen)
    }

    private func showFallback(_ feedback: Feedback, on screen: NSScreen) {
        dismissal?.invalidate()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = Self.makeContent(feedback)
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: round(frame.midX - Self.size.width / 2),
                              y: round(frame.minY + 48),
                              width: Self.size.width, height: Self.size.height), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeIn)
            panel.animator().alphaValue = 1
        }
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissal = timer
    }

    func hide(immediately: Bool = false) {
        dismissal?.invalidate()
        dismissal = nil
        generation += 1
        if immediately { nativeOSD.invalidate() }
        guard let panel, panel.isVisible else { return }
        if immediately {
            panel.orderOut(nil)
            panel.alphaValue = 0
            return
        }
        let hiddenGeneration = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDMotion.duration(HUDMotion.fadeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == hiddenGeneration else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func makePanel() -> DisplayControlHUDPanel {
        let panel = DisplayControlHUDPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        // The recovery message must remain visible above an owned black-screen window.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }

    /// The live window and offscreen review use the same content.
    static func makeContent(_ feedback: Feedback) -> NSView {
        let content = NSView(frame: NSRect(origin: .zero, size: size))

        let symbol = feedback.control == .brightness ? "sun.max.fill"
            : feedback.error == nil && feedback.level?.current == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.contentTintColor = .labelColor
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false

        let monitor = label(feedback.monitorName, size: 12, weight: .medium, secondary: true)
        let control = feedback.control == .brightness ? "Brightness" : "Volume"
        let value: String
        if feedback.isBlackedOut { value = "Black screen" }
        else if feedback.error != nil { value = "\(control) unavailable" }
        else if let level = feedback.level { value = "\(control) \(Int((level.normalized * 100).rounded()))%" }
        else { value = control }
        let title = label(value, size: 17, weight: .semibold)
        let status = feedback.isPending ? "Updating…" : feedback.level == nil ? "Value unavailable" : "Confirmed"
        let detail = label(feedback.isBlackedOut ? "Brightness Up restores the picture. Escape clears all black screens." : feedback.error ?? status,
                           size: 11, weight: .regular, secondary: true)
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping

        let text = NSStackView(views: [monitor, title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let row = NSStackView(views: [image, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 30),
            image.heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        // Native materials and semantic colors track system appearance, transparency and contrast.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .regular
            glass.cornerRadius = 20
            glass.contentView = content
            return glass
        }

        let background = NSVisualEffectView(frame: content.frame)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return background
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                              secondary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }
}

private final class DisplayControlHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
