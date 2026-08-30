import AppCore
import SwiftUI

/// The shell's frame around a tool's own settings: the hero header (icon, name, one-line
/// summary) and the enable switch, with `tool.makeSettingsPane()` below it.
///
/// The header is drawn HERE, not by the tools. Tools written by different people would
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
        VStack(spacing: 8) {
            // The switch is centred on the ICON row, not pinned to the scroll area's corner.
            // Anchored to the corner it reads as a stray control floating over the pane; on the
            // icon's centre line it reads as part of the header — the same relationship Raycast's
            // top-right toggle has with its extension header.
            //
            // It sits on the 540pt CONTENT gutter, not on the pane edge. Pinned to the edge it
            // overhung the column every section below it lines up on by 55pt (measured), which is
            // what made it read as floating rather than as the header's own control.
            ToolIcon(id: id, size: 72)
                .padding(.bottom, 2)
                .frame(width: SettingsMetrics.contentWidth)
                .overlay(alignment: .trailing) {
                    Toggle("", isOn: $isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Enable \(title)")
                        .help(isOn ? "Turn \(title) off" : "Turn \(title) on")
                }
                .frame(maxWidth: .infinity)
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440) // a one-line summary shouldn't span the whole detail area
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .padding(.horizontal, 22)
    }
}
