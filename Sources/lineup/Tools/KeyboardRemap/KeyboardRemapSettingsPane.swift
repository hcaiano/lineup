import AppCore
import Carbon
import KeyboardRemapCore
import SwiftUI

struct KeyboardRemapSettingsPane: View {
    @ObservedObject var tool: KeyboardRemapTool
    @StateObject private var labels = KeyboardLayoutLabels()
    @State private var selectedKeyboardID = "builtIn"
    @State private var addingMapping = false
    @State private var addingSwap = false

    private struct KeyboardChoice: Identifiable {
        let id: String
        let selector: KeyboardSelector
        let name: String
    }

    private var keyboards: [KeyboardChoice] {
        var choices = [KeyboardChoice(id: "builtIn", selector: .builtIn,
                                      name: tool.devices.contains(where: \.isBuiltIn)
                                      ? "Built-in keyboard" : "Built-in keyboard · Disconnected")]
        for device in tool.devices where !device.isBuiltIn {
            // Saved fingerprints survive a changed Product label after reconnecting.
            let selector = tool.settings.rules.first { $0.selector.matches(device: device) }?.selector
                ?? KeyboardSelector(device: device)
            let id = selectorID(selector)
            guard !choices.contains(where: { $0.id == id }) else { continue }
            let transport = device.transport.map { " · \($0)" } ?? ""
            choices.append(KeyboardChoice(id: id, selector: selector, name: device.product + transport))
        }
        for rule in tool.settings.rules {
            let id = selectorID(rule.selector)
            guard !choices.contains(where: { $0.id == id }) else { continue }
            choices.append(KeyboardChoice(id: id, selector: rule.selector,
                                          name: rule.selector.displayName + " · Disconnected"))
        }
        return choices
    }

    private var selectedKeyboard: KeyboardChoice {
        keyboards.first { $0.id == selectedKeyboardID } ?? keyboards[0]
    }

    private var mappings: [KeyboardRemapSettings.Pair] {
        tool.rule(for: selectedKeyboard.selector)?.mappings ?? []
    }

    private var canRetryMappings: Bool {
        tool.canEdit && tool.message == nil
            && (tool.recoveryMessage != nil || (tool.isRunning && tool.mappingMessage != nil))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let message = tool.blockedMessage ?? tool.message ?? tool.recoveryMessage
                ?? (tool.isRunning ? tool.mappingMessage : nil) {
                PinnedBannerStrip {
                    BlockedBanner(message: message, systemImage: "exclamationmark.triangle.fill",
                                  actionTitle: canRetryMappings ? "Retry mappings" : nil,
                                  action: canRetryMappings ? { tool.retry() } : nil)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    SettingsSectionView("Keyboard") {
                        SettingsRow(title: "Remap on") {
                            Picker("Keyboard", selection: $selectedKeyboardID) {
                                ForEach(keyboards) { keyboard in
                                    Text(keyboard.name).tag(keyboard.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 230)
                        }
                        if selectedKeyboard.selector == .builtIn {
                            SettingsRow(title: presetDescription, detail: "Swap these two keys, including Shift.") {
                                Button(isISOSwapSaved ? "Swap saved" : "Swap these keys") { tool.useISOPreset() }
                                    .disabled(!tool.canEdit || isISOSwapSaved)
                                    .accessibilityLabel(isISOSwapSaved ? "ISO and grave key swap saved"
                                                        : "Swap ISO and grave keys on the built-in keyboard")
                                    .help("Swap the two keys on the built-in ISO keyboard")
                            }
                        }
                        SettingsRow(title: "Status", detail: tool.status(for: selectedKeyboard.selector)) {
                            Button("Refresh") { tool.refreshKeyboards() }
                        }
                    }

                    SettingsSectionView("Key mappings", caption: "Choose what each key does. Shift follows the new key.") {
                        if mappings.isEmpty {
                            SettingsRow(title: "No mappings for this keyboard") { EmptyView() }
                        } else {
                            HStack {
                                Text("Press this key").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Use as this key").frame(maxWidth: .infinity, alignment: .leading)
                                Spacer().frame(width: 28)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                            ForEach(mappings) { pair in
                                mappingRow(pair)
                            }
                        }
                        HStack {
                            Button("Add mapping") { addingSwap = false; addingMapping = true }
                            Button("Swap two keys") { addingSwap = true; addingMapping = true }
                            Spacer()
                            if tool.rule(for: selectedKeyboard.selector) != nil {
                                Button("Remove all") { tool.removeRules(selector: selectedKeyboard.selector) }
                                    .help("Remove the saved mappings for this keyboard")
                            }
                        }
                        .disabled(!tool.canEdit)
                        .padding(.vertical, 10)
                    }

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            SettingsRow(title: "Show symbols for") {
                                Picker("Layout for key labels", selection: Binding(
                                    get: { tool.settings.inputSourceID ?? "" },
                                    set: { tool.setInputSource($0.isEmpty ? nil : $0) })) {
                                    Text("Current: \(labels.currentName)").tag("")
                                    ForEach(labels.layouts) { layout in Text(layout.name).tag(layout.id) }
                                    if let saved = tool.settings.inputSourceID,
                                       !labels.layouts.contains(where: { $0.id == saved }) {
                                        Text("Unavailable saved layout").tag(saved)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 260)
                                .disabled(!tool.canEdit)
                            }
                            SettingsCaption(text: "Symbols show the key with and without Shift. This changes labels only; your macOS keyboard layout stays the same.")
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack {
                            Text("Key labels")
                            Spacer()
                            Text(labels.name(for: tool.settings.inputSourceID))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    SettingsCaption(text: tool.isRunning ? "Each keyboard keeps its own settings."
                                    : "Turn on Keyboard Remap above to apply these mappings.")
                }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.vertical, SettingsMetrics.panePaddingVertical)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { tool.paneDidAppear(); labels.refresh() }
        .onDisappear { tool.paneDidDisappear() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in
            labels.refresh()
        }
        .sheet(isPresented: $addingMapping) {
            KeyboardMappingSheet(tool: tool, labels: labels, selector: selectedKeyboard.selector,
                                 swap: addingSwap)
        }
    }

    private var presetDescription: String {
        let section = labels.symbols(for: PhysicalKey.isoSection.hidUsage, inputSourceID: tool.settings.inputSourceID)
            ?? "ISO section"
        let grave = labels.symbols(for: PhysicalKey.grave.hidUsage, inputSourceID: tool.settings.inputSourceID)
            ?? "Grave / tilde"
        return "\(section) ↔ \(grave)"
    }

    private var isISOSwapSaved: Bool {
        mappings.contains { $0.source == PhysicalKey.isoSection.hidUsage && $0.destination == PhysicalKey.grave.hidUsage }
            && mappings.contains { $0.source == PhysicalKey.grave.hidUsage && $0.destination == PhysicalKey.isoSection.hidUsage }
    }

    private func mappingRow(_ pair: KeyboardRemapSettings.Pair) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                keyPicker("Press this key", selected: pair.source) { source in
                    tool.editMapping(selector: selectedKeyboard.selector, id: pair.id, source: source)
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                keyPicker("Use as this key", selected: pair.destination) { destination in
                    tool.editMapping(selector: selectedKeyboard.selector, id: pair.id, destination: destination)
                }
                Button {
                    tool.removeMapping(selector: selectedKeyboard.selector, id: pair.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove mapping from \(labels.label(for: pair.source, inputSourceID: tool.settings.inputSourceID))")
                .help("Remove this mapping")
            }
            .disabled(!tool.canEdit)
            .padding(.vertical, 10)
            Divider()
        }
    }

    private func keyPicker(_ title: String, selected: UInt64, set: @escaping (UInt64) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selected }, set: set)) {
            ForEach(PhysicalKey.catalog) { key in
                Text(labels.label(for: key.hidUsage, inputSourceID: tool.settings.inputSourceID)).tag(key.hidUsage)
            }
            if PhysicalKey.key(for: selected) == nil {
                Text(labels.label(for: selected, inputSourceID: tool.settings.inputSourceID)).tag(selected)
            }
        }
        .labelsHidden()
        .help(labels.label(for: selected, inputSourceID: tool.settings.inputSourceID))
        .frame(maxWidth: .infinity)
    }

    private func selectorID(_ selector: KeyboardSelector) -> String {
        if selector == .builtIn { return "builtIn" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(selector).base64EncodedString()) ?? selector.displayName
    }
}

private struct KeyboardMappingSheet: View {
    @ObservedObject var tool: KeyboardRemapTool
    @ObservedObject var labels: KeyboardLayoutLabels
    let selector: KeyboardSelector
    let swap: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var source = PhysicalKey.isoSection.hidUsage
    @State private var destination = PhysicalKey.grave.hidUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(swap ? "Swap two keys" : "Add a key mapping").font(.headline)
            Text(swap ? "Each key works as the other key, including Shift." : "Choose a key and what it should do, including Shift.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            keyPicker(swap ? "First key" : "Press this key", selection: $source)
            keyPicker(swap ? "Second key" : "Use as this key", selection: $destination)
            if source == destination {
                Text("Choose two different keys.").font(.callout)
            }
            if let message = tool.message {
                BlockedBanner(message: message, systemImage: "exclamationmark.triangle.fill")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(swap ? "Add swap" : "Add mapping") {
                    if tool.addMapping(selector: selector, source: source, destination: destination, swap: swap) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source == destination || !tool.canEdit)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func keyPicker(_ title: String, selection: Binding<UInt64>) -> some View {
        Picker(title, selection: selection) {
            ForEach(PhysicalKey.catalog) { key in
                Text(labels.label(for: key.hidUsage, inputSourceID: tool.settings.inputSourceID)).tag(key.hidUsage)
            }
        }
    }
}
