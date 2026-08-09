import AppCore
import SwiftUI

/// The shell's frame around a tool's own settings: the hero header (icon, name, one-line
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
    @ViewBuilder var content: () -> Content

    var body: some View {
        // The GeometryReader is load-bearing, not decoration. The header is a fixed block above a
        // scrolling pane, and that combination makes the stack report an ideal height of
        // header + FULL scroll content (a ScrollView's ideal height is its content's). The window
        // honours that ideal, and with a tall pane — Zones has thirteen shortcut rows — the whole
        // split view slides up out of the window: no header, a clipped sidebar, rows under the
        // title bar. A GeometryReader takes whatever size it is offered and does not pass its
        // child's ideal upward, so the pane gets exactly the window and scrolls inside it.
        GeometryReader { _ in
            VStack(spacing: 0) {
                header
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
    }

    private var header: some View {
        VStack(spacing: 8) {
            // The switch is centred on the ICON row, not pinned to the scroll area's corner.
            // Anchored to the corner it reads as a stray control floating over the pane; on the
            // icon's centre line it reads as part of the header — the same relationship Raycast's
            // top-right toggle has with its extension header.
            ToolIcon(id: id, size: 72)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    Toggle("", isOn: $isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Enable \(title)")
                        .help(isOn ? "Turn \(title) off" : "Turn \(title) on")
                }
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
