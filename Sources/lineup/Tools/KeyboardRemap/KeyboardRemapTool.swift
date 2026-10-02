import AppKit
import AppCore
import KeyboardRemapCore
import SwiftUI

@MainActor
final class KeyboardRemapTool: Tool, ObservableObject {
    let id = ToolID.keyboardRemap
    let displayName = "Keyboard Remap"
    let summary = "Remap physical keys on the keyboards you choose."
    let iconSymbol = "keyboard"
    let requiredPermissions: Set<Permission> = []
    let defaultEnabled = false

    @Published private(set) var isRunning = false
    @Published private(set) var settings = KeyboardRemapSettings()
    @Published private(set) var devices: [KeyboardDevice] = []
    @Published private(set) var sectionLoadError: String?
    @Published private(set) var message: String?
    @Published private(set) var saveMessage: String?
    @Published private(set) var mappingMessage: String?
    @Published private(set) var recoveryMessage: String?
    @Published private(set) var deviceStatuses: [UInt64: String] = [:]
    @Published private(set) var appliedDeviceIDs: Set<UInt64> = []
    private var services: ToolServices?
    private var observerID: UUID?
    private var paneVisible = false

    var blockedMessage: String? { sectionLoadError ?? services?.config.blockedMessage }
    var canEdit: Bool { blockedMessage == nil && services?.config.canWrite == true }
    var canRetryMappings: Bool {
        canEdit && (recoveryMessage != nil || (isRunning && mappingMessage != nil))
    }

    func attach(_ services: ToolServices) {
        self.services = services
        loadSettings()
    }

    private func loadSettings() {
        guard let services else { return }
        do {
            settings = try services.config.load(KeyboardRemapSettings.self) ?? KeyboardRemapSettings()
            sectionLoadError = nil
        } catch {
            sectionLoadError = "Keyboard Remap settings could not be read and were left untouched. Quit Lineup before restoring valid settings, then reopen it. Settings from a newer version require updating Lineup."
            services.log.error("Keyboard Remap settings could not be decoded: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start(_ services: ToolServices) {
        guard !isRunning else { return }
        self.services = services
        loadSettings()
        isRunning = true
        beginObserving()
        services.termination.addCleanup(id) { [weak self] in self?.releaseMappings() }
        apply()
    }

    func stop() {
        isRunning = false
        releaseMappings()
        services?.termination.removeCleanup(id)
        if !paneVisible { endObserving() }
    }

    private func releaseMappings() {
        services?.keyboardMappings.setKeyboardRemap([], enabled: false)
        refreshState()
    }

    func paneDidAppear() {
        clearEditingMessage()
        paneVisible = true
        // A disabled tool reads inventory here without installing mappings or an event tap.
        beginObserving()
        services?.keyboardMappings.refresh()
        refreshState()
    }

    func paneDidDisappear() {
        paneVisible = false
        if !isRunning { endObserving() }
    }

    private func beginObserving() {
        guard observerID == nil, let services else { return }
        observerID = services.keyboardMappings.observe { [weak self] in self?.refreshState() }
        refreshState()
    }

    private func endObserving() {
        if let observerID { services?.keyboardMappings.removeObserver(observerID) }
        observerID = nil
    }

    private func refreshState() {
        guard let manager = services?.keyboardMappings else { return }
        devices = manager.devices
        mappingMessage = manager.remapStatus
        recoveryMessage = manager.recoveryStatus
        deviceStatuses = manager.remapDeviceStatuses
        appliedDeviceIDs = manager.appliedRemapDeviceIDs
        services?.refreshMenu()
    }

    private func apply() {
        guard isRunning, let manager = services?.keyboardMappings else { return }
        manager.setKeyboardRemap(canEdit ? settings.ruleSets : [], enabled: canEdit)
    }

    func retry() {
        guard canRetryMappings else { return }
        services?.keyboardMappings.retry()
    }

    func refreshKeyboards() { services?.keyboardMappings.refresh() }

    func clearEditingMessage() {
        guard message != nil else { return }
        message = nil
        services?.refreshMenu()
    }

    @discardableResult
    private func save(applyMappings: Bool = true, _ edit: (inout KeyboardRemapSettings) -> Void) -> Bool {
        guard canEdit, let services else { return false }
        var proposed = settings
        edit(&proposed)
        guard proposed.isValid else {
            message = "Each source key needs one different destination. Edit the existing mapping before adding this key again."
            return false
        }
        message = nil
        do {
            try services.config.save(proposed)
            settings = proposed
            saveMessage = nil
            if applyMappings { apply() }
            services.refreshMenu()
            return true
        } catch {
            saveMessage = "Keyboard Remap settings could not be saved. Your previous mappings are still in use."
            services.refreshMenu()
            return false
        }
    }

    func setInputSource(_ id: String?) {
        _ = save(applyMappings: false) { $0.inputSourceID = id }
    }

    func rule(for selector: KeyboardSelector) -> KeyboardRemapSettings.Rule? {
        settings.rules.first { $0.selector == selector }
    }

    @discardableResult
    func addMapping(selector: KeyboardSelector, source: UInt64, destination: UInt64, swap: Bool) -> Bool {
        guard selector.isValid else {
            message = "This keyboard could not be identified safely. Reconnect it, then refresh the keyboard list."
            return false
        }
        return save { proposed in
            let index: Int
            if let existing = proposed.rules.firstIndex(where: { $0.selector == selector }) {
                index = existing
            } else {
                proposed.rules.append(.init(selector: selector))
                index = proposed.rules.count - 1
            }
            proposed.rules[index].mappings.append(.init(source: source, destination: destination))
            if swap { proposed.rules[index].mappings.append(.init(source: destination, destination: source)) }
        }
    }

    func editMapping(selector: KeyboardSelector, id: String, source: UInt64? = nil, destination: UInt64? = nil) {
        _ = save { proposed in
            guard let rule = proposed.rules.firstIndex(where: { $0.selector == selector }),
                  let pair = proposed.rules[rule].mappings.firstIndex(where: { $0.id == id }) else { return }
            if let source { proposed.rules[rule].mappings[pair].source = source }
            if let destination { proposed.rules[rule].mappings[pair].destination = destination }
        }
    }

    func removeMapping(selector: KeyboardSelector, id: String) {
        _ = save { proposed in
            guard let rule = proposed.rules.firstIndex(where: { $0.selector == selector }) else { return }
            proposed.rules[rule].mappings.removeAll { $0.id == id }
        }
    }

    func removeRules(selector: KeyboardSelector) {
        _ = save { $0.rules.removeAll { $0.selector == selector } }
    }

    func useISOPreset() {
        _ = save { proposed in
            let index: Int
            if let existing = proposed.rules.firstIndex(where: { $0.selector == .builtIn }) { index = existing }
            else {
                proposed.rules.append(.init(selector: .builtIn))
                index = proposed.rules.count - 1
            }
            let keys = [PhysicalKey.isoSection.hidUsage, PhysicalKey.grave.hidUsage]
            for (source, destination) in [(keys[0], keys[1]), (keys[1], keys[0])] {
                if let pair = proposed.rules[index].mappings.firstIndex(where: { $0.source == source }) {
                    proposed.rules[index].mappings[pair].destination = destination
                } else {
                    proposed.rules[index].mappings.append(.init(source: source, destination: destination))
                }
            }
        }
    }

    func status(for selector: KeyboardSelector) -> String {
        guard selector.isValid else {
            return "This keyboard could not be identified safely. Reconnect it, then refresh the keyboard list."
        }
        let connected = devices.filter { selector.matches(device: $0) }
        guard !connected.isEmpty else { return "Disconnected. Saved rules apply when this keyboard reconnects." }
        if let blockedMessage { return blockedMessage }
        if let recoveryMessage { return recoveryMessage }
        let problems = connected.compactMap { deviceStatuses[$0.registryID] }.filter { $0 != "Applied" }
        if !problems.isEmpty { return problems.joined(separator: " ") }
        guard isRunning else { return "Off. Saved mappings are ready to apply when Keyboard Remap is enabled." }
        guard let rule = rule(for: selector), !rule.mappings.isEmpty else { return "No mappings. This keyboard keeps its normal behavior." }
        if connected.allSatisfy({ appliedDeviceIDs.contains($0.registryID) }) {
            return "Applied. \(rule.mappings.count) physical-key mappings."
        }
        return "Applying saved mappings…"
    }

    var warnings: [ToolWarning] {
        if let blockedMessage { return [ToolWarning(id: "keyboardRemap.config", text: blockedMessage)] }
        if let message { return [ToolWarning(id: "keyboardRemap.edit", text: message)] }
        if let saveMessage { return [ToolWarning(id: "keyboardRemap.save", text: saveMessage)] }
        if let recoveryMessage {
            return [ToolWarning(id: "keyboardRemap.recovery", text: recoveryMessage,
                                actionTitle: canRetryMappings ? "Retry keyboard mappings" : nil,
                                action: canRetryMappings ? { [weak self] in self?.retry() } : nil)]
        }
        guard isRunning, let mappingMessage else { return [] }
        return [ToolWarning(id: "keyboardRemap.mapping", text: mappingMessage,
                            actionTitle: canRetryMappings ? "Retry keyboard mappings" : nil,
                            action: canRetryMappings ? { [weak self] in self?.retry() } : nil)]
    }

    func makeQuickPanel() -> AnyView? { AnyView(KeyboardRemapQuickPanel(tool: self)) }

    func menuItems() -> [NSMenuItem] {
        let count = settings.rules.reduce(0) { $0 + $1.mappings.count }
        var items = [ToolMenu.info("\(count) saved physical-key mappings")]
        if canRetryMappings {
            items.append(ToolMenu.item("Retry keyboard mappings", symbol: "arrow.clockwise") { [weak self] in self?.retry() })
        }
        return items
    }

    func makeSettingsPane() -> AnyView { AnyView(KeyboardRemapSettingsPane(tool: self)) }
}
