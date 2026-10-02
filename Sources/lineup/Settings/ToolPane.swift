import AppCore
import SwiftUI

/// The shell's frame around a tool's own settings: the header row (icon, name, one-line
/// summary) and the enable switch, with `tool.makeSettingsPane()` below it.
///
/// The header is drawn HERE, not by the tools. Three tools written by three people would
/// otherwise each invent their own title treatment, and the enable switch — which is shell
/// state, not tool state — would have to be threaded into every pane. Tools keep supplying only
/// their own controls.
///
/// The switch lives in the header rather than in the sidebar because that is where a user looks
/// after opening a tool they have never used: the pane answers "what is this and is it on?"
/// before it offers any settings. The content below stays live while the tool is off, so a tool
/// can be configured before it is switched on.
struct ToolPane<Content: View>: View {
    let id: ToolID
    let title: String
    let summary: String
    @Binding var isOn: Bool
    /// Why the last flip of the switch did not take, if it did not. Passed in rather than read
    /// from the environment: the header has one owner (`SettingsStore.pane(for:)`) and this way
    /// it cannot be built without one.
    var enableError: String?
    var onDismissEnableError: () -> Void = {}
    @ViewBuilder var content: () -> Content

    var body: some View {
        // The GeometryReader is load-bearing, not decoration. The header is a fixed block above a
        // scrolling pane, and that combination makes the stack report an ideal height of
        // header + FULL scroll content (a ScrollView's ideal height is its content's). The window
        // honours that ideal, and with a tall pane — Zones has sixteen shortcut rows — the whole
        // split view slides up out of the window: no header, a clipped sidebar, rows under the
        // title bar. A GeometryReader takes whatever size it is offered and does not pass its
        // child's ideal upward, so the pane gets exactly the window and scrolls inside it.
        GeometryReader { _ in
            VStack(spacing: 0) {
                header
                // The switch reads through to the persisted flag, so a refused write already puts
                // it back. Without a line saying why, that looks like the click was simply lost.
                if let message = enableError {
                    PinnedBannerStrip {
                        BlockedBanner(message: message,
                                      systemImage: "exclamationmark.triangle.fill")
                    }
                }
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        // The message describes the toggle the user just clicked; leaving the pane retires it.
        .onDisappear(perform: onDismissEnableError)
    }

    private var header: some View {
        // One row on the content column, as System Settings draws a feature's header: the icon,
        // what the tool does, and its switch on the same line as the name. The switch reads as
        // the answer to "is this on?" rather than a control floating at the pane's corner, and
        // the row leaves most of a 560pt window to the settings themselves.
        HStack(alignment: .center, spacing: 14) {
            ToolIcon(id: id, size: 56, isEnabled: isOn)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The text takes the row's free width; a Spacer would split it and wrap the summary early.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 16)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Enable \(title)")
                .help(isOn ? "Turn \(title) off" : "Turn \(title) on")
        }
        .frame(width: SettingsMetrics.contentWidth)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}
