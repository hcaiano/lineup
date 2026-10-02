import AppKit
import AppCore
import ScreenCaptureKit
import SwiftUI
import TextCaptureCore
import Vision

@MainActor
final class TextCaptureTool: Tool, ObservableObject {
    let id = ToolID.textCapture
    var displayName: String { id.displayName }
    let summary = "Copy text from a selected screen region."
    let iconSymbol = "text.viewfinder"
    let requiredPermissions: Set<Permission> = [.screenRecording]
    let defaultEnabled = false

    @Published private(set) var isRunning = false
    @Published private(set) var settings = TextCaptureSettings()
    @Published private(set) var message: String?
    @Published private(set) var shortcutFailure: String?
    @Published private(set) var shortcutMessage: String?
    @Published private(set) var sectionUnreadable = false
    @Published private(set) var needsPermission = false
    @Published private(set) var isCapturing = false

    private var services: ToolServices?
    private var session = CaptureSession()
    private var overlay: TextCaptureOverlay?
    private var frameCapture: TextCaptureFrame?
    private var request: VNRecognizeTextRequest?
    private var work: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let notice = TextCaptureNotice()

    var canEdit: Bool { !sectionUnreadable && (services?.config.canWrite ?? false) }
    var blockedMessage: String? {
        sectionUnreadable
            ? "Text Capture settings could not be read. They were left untouched. Repair the textCapture section in config.json and restart Lineup."
            : services?.config.blockedMessage
    }

    func attach(_ services: ToolServices) {
        self.services = services
        do {
            settings = try services.config.load(TextCaptureSettings.self) ?? TextCaptureSettings()
            sectionUnreadable = false
        } catch {
            sectionUnreadable = true
        }
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        attach(services)
        isRunning = true
        registerShortcut()
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, self.isCapturing else { return }
            self.cancel()
            self.report("Displays changed. Capture cancelled; clipboard unchanged.")
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in
            self?.cancel()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.cancel()
        }
        observe(.default, NSApplication.didBecomeActiveNotification) { [weak self] in
            guard let self else { return }
            if self.services?.permissions.isScreenRecordingGranted == true { self.needsPermission = false }
            if self.shortcutFailure != nil, self.services?.hotkeys.isSuspended == false {
                self.registerShortcut()
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: NSNotification.Name,
                         action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    func stop() {
        isRunning = false
        cancel()
        services?.hotkeys.unregisterAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        shortcutFailure = nil
    }

    func cancel() {
        session.cancel()
        work?.cancel()
        work = nil
        request?.cancel()
        request = nil
        frameCapture?.cancel()
        frameCapture = nil
        overlay?.close()
        overlay = nil
        notice.hide()
        isCapturing = false
        services?.refreshMenu()
    }

    func invoke() {
        guard isRunning, let services, let token = session.begin() else { return }
        isCapturing = true
        message = nil
        notice.hide()
        // Reserving the session before prompting prevents nested activations in a modal run loop.
        guard services.permissions.isScreenRecordingGranted || services.permissions.requestScreenRecording() else {
            fail(token, error: TextCaptureError.permissionDenied)
            return
        }
        guard session.token == token, isRunning else { return }
        needsPermission = false
        do { request = try TextCaptureRecognition.request() }
        catch { fail(token, error: error); return }
        let displays = TextCaptureDisplay.current()
        guard !displays.isEmpty else { fail(token, error: TextCaptureError.displayChanged); return }
        let overlay = TextCaptureOverlay()
        self.overlay = overlay
        overlay.show(displays: displays, select: { [weak self] display, rect in
            self?.recognize(token: token, display: display, selection: rect, topology: displays)
        }, cancel: { [weak self] in self?.cancel() })
        services.refreshMenu()
    }

    private func recognize(token: UUID, display: TextCaptureDisplay, selection: CGRect,
                           topology: [TextCaptureDisplay]) {
        guard session.token == token, work == nil,
              let region = CaptureRegion(selection: selection, displayFrame: display.frame, scale: display.scale),
              let request else { return }
        let overlayIDs = overlay?.windowIDs ?? []
        work = Task { [weak self] in
            guard let self else { return }
            do {
                // Query while the overlays still exist, so the exclusion list is explicit even
                // if the compositor has not processed their subsequent order-out yet.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try self.validate(token, topology: topology)
                guard let scDisplay = content.displays.first(where: { $0.displayID == display.id })
                else { throw TextCaptureError.displayChanged }
                let excluded = content.windows.filter { overlayIDs.contains($0.windowID) }
                guard Set(excluded.map(\.windowID)) == overlayIDs else {
                    throw TextCaptureError.captureFailed
                }
                self.overlay?.close()
                self.overlay = nil
                let capture = TextCaptureFrame()
                self.frameCapture = capture
                let image = try await capture.capture(display: scDisplay, region: region, excluding: excluded)
                try self.validate(token, topology: topology)
                self.frameCapture = nil
                let text = try await TextCaptureRecognition.recognize(image, request: request)
                try self.validate(token, topology: topology)
                self.complete(token, text: text)
            } catch {
                self.fail(token, error: error)
            }
        }
    }

    private func validate(_ token: UUID, topology: [TextCaptureDisplay]) throws {
        try Task.checkCancellation()
        guard isRunning, session.token == token else { throw CancellationError() }
        guard TextCaptureDisplay.current() == topology else { throw TextCaptureError.displayChanged }
        guard services?.permissions.isScreenRecordingGranted == true else { throw TextCaptureError.permissionDenied }
    }

    private func complete(_ token: UUID, text: String) {
        let outcome = session.finish(token, text: text)
        guard outcome != .ignored else { return }
        cancel()
        switch outcome {
        case .copy(let value):
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(value, forType: .string) {
                report("Text copied. Paste with Command-V.", success: true)
            } else {
                report("The clipboard is unavailable. Try capturing again.")
            }
        case .empty: report("No text found. Clipboard unchanged. Try a larger, clearer region.")
        case .failed, .ignored: break
        }
    }

    private func fail(_ token: UUID, error: Error) {
        guard session.finish(token, text: nil) != .ignored else { return }
        cancel()
        if error is CancellationError { return }
        if services?.permissions.isScreenRecordingGranted == false || (error as? TextCaptureError) == .permissionDenied {
            needsPermission = true
            report("Allow Screen Recording in System Settings, then quit and reopen Lineup if asked. Clipboard unchanged.")
        } else if (error as? TextCaptureError) == .languagesUnavailable {
            report("Portuguese and English recognition are not both available on this Mac. Update macOS and try again. Clipboard unchanged.")
        } else if (error as? TextCaptureError) == .displayChanged {
            report("Displays changed. Capture cancelled; clipboard unchanged.")
        } else {
            report("Text Capture failed. Try again, or check Screen Recording in System Settings. Clipboard unchanged.")
        }
    }

    private func report(_ text: String, success: Bool = false) {
        // Status only. Neither captured pixels, recognized text, nor framework errors are logged.
        message = text
        notice.show(text, success: success)
        services?.refreshMenu()
    }

    func openPermissionSettings() { services?.permissions.openScreenRecordingSettings() }

    func setShortcut(_ shortcut: TextCaptureSettings.Shortcut?) {
        guard canEdit, let services else { return }
        if let shortcut {
            guard shortcut.isValid else { return }
            if let owner = services.boundCombos().conflictOwner(keyCode: shortcut.keyCode,
                                                               modifiers: shortcut.modifiers, excluding: id) {
                shortcutMessage = "That shortcut is \(HotkeyFailure.ownedByTool(owner).displayReason). Choose another shortcut."
                return
            }
        }
        var updated = settings
        updated.shortcut = shortcut
        do {
            try services.config.save(updated)
            settings = updated
            shortcutMessage = nil
            if isRunning { registerShortcut() }
        } catch {
            shortcutMessage = "The shortcut could not be saved. Your previous shortcut is unchanged."
        }
    }

    func persistedCombos() -> [(keyCode: Int, modifiers: UInt32)] {
        guard !sectionUnreadable, let shortcut = settings.shortcut else { return [] }
        return [(shortcut.keyCode, shortcut.modifiers)]
    }

    func registerShortcut() {
        guard isRunning, let services else { return }
        services.hotkeys.unregisterAll()
        shortcutFailure = nil
        guard !sectionUnreadable, let shortcut = settings.shortcut else { return }
        let result = services.hotkeys.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.invoke()
        }
        if case .failure(let failure) = result {
            shortcutFailure = "Text Capture shortcut: \(failure.displayReason). Choose another shortcut or retry."
        }
        services.refreshMenu()
    }

    func hotkeysFailedToRestore(_ failures: [HotkeyRestoreFailure]) {
        guard !failures.isEmpty else { return }
        shortcutFailure = "The shortcut could not be restored. Choose another shortcut or retry."
        services?.refreshMenu()
    }

    func makeQuickPanel() -> AnyView? {
        let shortcut = settings.shortcut.map { ShortcutKit.display(keyCode: $0.keyCode, modifiers: $0.modifiers) } ?? ""
        return AnyView(TextCaptureQuickPanel(isCapturing: isCapturing, isRunning: isRunning,
                                             shortcut: shortcut, warnings: warnings,
                                             capture: { [weak self] in self?.invoke() },
                                             cancel: { [weak self] in self?.cancel() }))
    }

    func menuItems() -> [NSMenuItem] {
        if isCapturing {
            return [ToolMenu.item("Cancel Text Capture", symbol: "xmark") { [weak self] in self?.cancel() }]
        }
        return [ToolMenu.item("Capture Text…", symbol: iconSymbol) { [weak self] in self?.invoke() }]
    }

    var warnings: [ToolWarning] {
        var warnings: [ToolWarning] = []
        if sectionUnreadable, let blockedMessage {
            warnings.append(ToolWarning(id: "textCapture.config", text: blockedMessage))
        }
        if needsPermission {
            warnings.append(ToolWarning(id: "textCapture.screenRecording", text: "Text Capture needs Screen Recording",
                                        actionTitle: "Open Screen Recording Settings…",
                                        action: { [weak self] in self?.openPermissionSettings() }))
        }
        if let shortcutFailure {
            warnings.append(ToolWarning(id: "textCapture.shortcut", text: shortcutFailure,
                                        actionTitle: "Retry Text Capture shortcut",
                                        action: { [weak self] in self?.registerShortcut() }))
        }
        return warnings
    }

    func makeSettingsPane() -> AnyView { AnyView(TextCaptureSettingsPane(tool: self)) }
}
