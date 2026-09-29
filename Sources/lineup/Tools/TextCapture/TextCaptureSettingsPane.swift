import AppCore
import SwiftUI

struct TextCaptureSettingsPane: View {
    @ObservedObject var tool: TextCaptureTool
    @EnvironmentObject private var settings: SettingsStore

    var body: some View { TextCaptureSettingsBody(tool: tool, settings: settings) }
}

private struct TextCaptureSettingsBody: View {
    @ObservedObject var tool: TextCaptureTool
    @StateObject private var recorder: ShortcutRecorder

    init(tool: TextCaptureTool, settings: SettingsStore) {
        self.tool = tool
        _recorder = StateObject(wrappedValue: ShortcutRecorder(store: settings))
    }

    private var shortcutText: String {
        guard let shortcut = tool.settings.shortcut else { return "" }
        return ShortcutKit.display(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let blocked = tool.blockedMessage {
                PinnedBannerStrip { BlockedBanner(message: blocked) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    SettingsSectionView("Capture") {
                        SettingsRow(title: "Select a region",
                                    detail: "Drag around text on one display. Escape cancels. Paste the copied text with Command-V.") {
                            Button(tool.isCapturing ? "Cancel capture" : "Capture Text…") {
                                recorder.cancel()
                                if tool.isCapturing { tool.cancel() } else { tool.invoke() }
                            }
                            .disabled(!tool.isRunning)
                        }
                    }
                    SettingsSectionView("Global shortcut") {
                        SettingsRow(title: "Capture text", detail: "Record a shortcut. Delete clears it; Escape cancels recording.") {
                            ShortcutField(text: shortcutText, isRecording: recorder.isRecording("capture"),
                                          enabled: tool.canEdit, accessibilityLabel: "Capture text shortcut",
                                          rejectionCount: recorder.rejectionCount) {
                                recorder.toggle("capture") { capture in
                                    switch capture {
                                    case .combo(let keyCode, let modifiers):
                                        tool.setShortcut(.init(keyCode: keyCode, modifiers: modifiers))
                                    case .clear: tool.setShortcut(nil)
                                    case .modifiersOnly: break
                                    }
                                }
                            }
                        }
                        if let message = tool.shortcutMessage {
                            Text(message).accessibilityLabel("Shortcut: \(message)")
                        }
                        if let failure = tool.shortcutFailure {
                            Text(failure).foregroundStyle(.primary)
                            Button("Retry shortcut") { tool.registerShortcut() }
                        }
                    }
                    SettingsSectionView("Recognition and privacy") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recognition uses Portuguese and English support in macOS. Captures and text are not saved by Lineup or sent to a service.")
                            Text("Screen Recording is requested when you first capture, not when you enable the tool.")
                                .foregroundStyle(.secondary)
                            Button("Open Screen Recording Settings…") { tool.openPermissionSettings() }
                        }
                    }
                    if let message = tool.message {
                        Text(message)
                            .accessibilityLabel("Text Capture status: \(message)")
                            .textSelection(.enabled)
                    }
                }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.vertical, SettingsMetrics.sectionSpacing)
                .frame(maxWidth: .infinity)
            }
        }
        .onDisappear { recorder.cancel() }
    }
}
