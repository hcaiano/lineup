import AppKit
import AppCore
import SwiftUI

/// Shared parts of the two onboarding windows (Welcome for a brand-new user, What's New for a
/// 1.x upgrade). Both have to answer "what are the tools and which are on?", so the tile
/// row and the banners are written once here rather than twice in slightly different words.

/// One tool as the onboarding windows describe it. The blurbs are shorter than the tools'
/// `summary` strings on purpose: all of them are read side by side.
struct OnboardingTool: Identifiable {
    let id: ToolID
    let name: String
    let blurb: String
    /// "On" / "Off by default" — the honest default state after a 2.0 install. A silent
    /// auto-update must never spontaneously arrange windows, start an event tap, or grab Caps
    /// Lock, so Tiles, Cycler and Hyperkey ship off and say so.
    let state: String
    let isOn: Bool
}

enum OnboardingCopy {
    static let tools: [OnboardingTool] = [
        OnboardingTool(id: .zones, name: "Zones",
                       blurb: "Snap and resize windows with a shortcut, or drag one onto a zone.",
                       state: "On", isOn: true),
        OnboardingTool(id: .tiles, name: "Tiles",
                       blurb: "Fill your Zones automatically, with four workspaces and stacks.",
                       state: "Off by default", isOn: false),
        OnboardingTool(id: .cycler, name: "Cycler",
                       blurb: "One shortcut jumps to an app; press it again to cycle its windows.",
                       state: "Off by default", isOn: false),
        OnboardingTool(id: .hyperkey, name: "Hyperkey",
                       blurb: "Turn Caps Lock into ⌃⌥⌘; add ⇧ if you want full Hyper.",
                       state: "Off by default", isOn: false),
    ]

    /// Accessibility is the one permission Lineup asks for up front. Input Monitoring is named
    /// here only so a new user knows it exists and knows it is not being asked for yet.
    static let accessibilityBody =
        "Zones, Tiles and Cycler need Accessibility to move and focus your windows. That is the only "
        + "permission Lineup asks for now, and it never collects your data."
    static let inputMonitoringNote =
        "Input Monitoring is asked for only when you turn Hyperkey on."
}

/// The tools as a row of app-icon tiles. This is the one view that makes Lineup read
/// as a suite rather than as "the window app, with extras".
struct ToolTileRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(OnboardingCopy.tools) { tool in
                VStack(spacing: 7) {
                    ToolIcon(id: tool.id, size: 52)
                    Text(tool.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(tool.state)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tool.isOn ? Color(nsColor: Brand.blue) : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(tool.isOn
                                           ? Color(nsColor: Brand.blue).opacity(0.13)
                                           : Color.secondary.opacity(0.12)))
                    Text(tool.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(tool.name), \(tool.state). \(tool.blurb)")
            }
        }
    }
}

/// A tinted note: the Cycler import confirmation, or the uninstall banner with its Reveal action.
struct OnboardingBanner: View {
    /// "Your shortcuts came across" is good news, and it is shown directly above a warning. Drawn
    /// in Cycler's red-orange accent the two banners were the same temperature, and the successful
    /// import read as a second problem.
    static let successTint = Color.green

    let symbol: String
    let tint: Color
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.10)))
    }
}

/// Everything the shell knows about a just-run legacy import, in the form the two windows show it.
struct OnboardingImportContext {
    /// "Imported 6 Cycler shortcuts and your Hyper Key setup", or nil.
    var cyclerSummary: String?
    /// Cycler.app is installed (running or not) — offer to reveal it so it can be removed.
    var revealCycler: (() -> Void)?
    /// Show the uninstall banner at all. True whenever anything came from standalone Cycler.
    var showUninstallBanner: Bool = false

    static let none = OnboardingImportContext()
}

/// Hosts a SwiftUI onboarding view in a plain titled window sized to its content.
@MainActor
enum OnboardingWindow {
    static func make<Content: View>(title: String, width: CGFloat,
                                    @ViewBuilder content: () -> Content) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView:
            content().frame(width: width).fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        return (window, host)
    }
}
