import AppCore
import SwiftUI

struct ScrollSettingsPane: View {
    @ObservedObject var tool: ScrollTool

    var body: some View {
        VStack(spacing: 0) {
            if let banner {
                PinnedBannerStrip {
                    BlockedBanner(message: banner.message, systemImage: "exclamationmark.triangle.fill",
                                  actionTitle: banner.actionTitle, action: banner.action)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    if tool.state == .idle {
                        SettingsCaption(text: "Nothing is reversed. Choose a device and a direction.",
                                        systemImage: "info.circle")
                    }
                    SettingsSectionView("Reverse scrolling", caption: directionCaption) {
                        toggle("Mouse", detail: "Scroll wheels and Magic Mouse.",
                               isOn: tool.settings.reverseMouse, set: tool.setReverseMouse)
                        toggle("Trackpad", detail: "Built-in trackpads and Magic Trackpad.",
                               isOn: tool.settings.reverseTrackpad, set: tool.setReverseTrackpad)
                    }
                    SettingsSectionView("Directions", caption: "Applies to each reversed device.") {
                        toggle("Vertical", detail: nil,
                               isOn: tool.settings.reverseVertical, set: tool.setReverseVertical)
                        toggle("Horizontal", detail: nil,
                               isOn: tool.settings.reverseHorizontal, set: tool.setReverseHorizontal)
                    }
                    if let message = tool.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsCaption(text: "Changes apply to the next scroll. Zoom, rotation and swipes between spaces are unchanged. Scrolling from other apps, such as remote control or mouse utilities, keeps the macOS direction. Turning Scroll off or quitting Lineup restores it immediately.")
                }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.vertical, SettingsMetrics.panePaddingVertical)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { tool.reconcile() }
    }

    /// The system preference is read, never changed, so the caption states what reversal means now.
    private var directionCaption: String {
        tool.systemUsesNaturalScrolling
            ? "Natural scrolling is on in macOS, so a reversed device scrolls the traditional way."
            : "Natural scrolling is off in macOS, so a reversed device scrolls the natural way."
    }

    private var banner: (message: String, actionTitle: String?, action: (() -> Void)?)? {
        if let blocked = tool.blockedMessage { return (blocked, nil, nil) }
        switch tool.state {
        case .needsAccessibility:
            return ("Allow Accessibility for Lineup to reverse scrolling. Until then, scrolling keeps the macOS direction.",
                    "Open Accessibility Settings…", { tool.openAccessibilitySettings() })
        case .refused:
            return ("macOS did not let Scroll read scroll events, so scrolling keeps the macOS direction. Check Lineup in Accessibility settings.",
                    "Try Again", { tool.reconcile() })
        case .unsupported:
            return ("Scroll can’t identify mice and trackpads on this macOS version, so scrolling keeps the macOS direction.",
                    nil, nil)
        default:
            return nil
        }
    }

    private func toggle(_ title: String, detail: String?, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        SettingsRow(title: title, detail: detail) {
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!tool.canEdit)
        }
    }
}
