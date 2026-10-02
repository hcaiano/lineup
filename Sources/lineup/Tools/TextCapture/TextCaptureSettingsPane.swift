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
                    // Screen Recording is asked for on the first capture. The way back to it
                    // only matters once it has been refused.
                    if tool.needsPermission {
                        BlockedBanner(message: "Text Capture needs Screen Recording to read the screen.",
                                      systemImage: "exclamationmark.triangle.fill",
                                      actionTitle: "Open Screen Recording Settings…",
                                      action: { tool.openPermissionSettings() })
                    }
                    SettingsSectionView("Capture") {
                        SettingsRow(title: "Capture text",
                                    detail: "Drag around text on screen, then paste it anywhere.") {
                            Button(tool.isCapturing ? "Cancel" : "Capture Text…") {
                                recorder.cancel()
                                if tool.isCapturing { tool.cancel() } else { tool.invoke() }
                            }
                            .disabled(!tool.isRunning)
                        }
                        SettingsRow(title: "Shortcut") {
                            ShortcutField(text: shortcutText, isRecording: recorder.isRecording("capture"), emptyText: "Click to set",
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
                            SettingsCaption(text: message)
                                .padding(.vertical, 8)
                                .accessibilityLabel("Shortcut: \(message)")
                        }
                        if let failure = tool.shortcutFailure {
                            HStack {
                                Text(failure).font(.callout).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 12)
                                Button("Retry") { tool.registerShortcut() }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    if let message = tool.message {
                        SettingsCaption(text: message, systemImage: "info.circle")
                            .accessibilityLabel("Text Capture status: \(message)")
                            .textSelection(.enabled)
                    }
                    SettingsCaption(text: "Text is recognized on your Mac, in Portuguese and English. Nothing is saved or sent.",
                                    systemImage: "lock")
                }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.vertical, SettingsMetrics.panePaddingVertical)
                .frame(maxWidth: .infinity)
            }
        }
        .onDisappear { recorder.cancel() }
    }
}
