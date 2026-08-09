import AppKit
import AppCore
import SwiftUI

/// The 1.x → 2.0 intro, shown ONCE to users who already had Lineup (`general.didShowWhatsNew2`).
///
/// Its whole job is to explain a rename and a scope change without alarming anyone: window
/// snapping did not go anywhere, it is now the Zones tool, and the two new tools are off until
/// the user turns them on. It asks for nothing — no permission is requested from this window,
/// because an existing user's Accessibility grant already persists and Input Monitoring is only
/// ever requested when Hyperkey is switched on.
@MainActor
final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let importContext: OnboardingImportContext
    private let onOpenSettings: () -> Void
    private let onClose: () -> Void

    init(importContext: OnboardingImportContext = .none,
         onOpenSettings: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.importContext = importContext
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        super.init()
    }

    /// Already-sized content for offscreen preview rendering, with both optional banners on so
    /// the tallest layout is what gets reviewed.
    static func makeEmbeddedContent() -> NSView {
        let host = NSHostingView(rootView: WhatsNewView(
            importContext: OnboardingImportContext(
                cyclerSummary: "Imported 6 Cycler shortcuts and your Hyper Key setup.",
                revealCycler: {}, showUninstallBanner: true),
            onOpenSettings: {}, onLater: {})
                .frame(width: Self.width)
                .fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        return host
    }

    private static let width: CGFloat = 520

    func show() {
        let (win, _) = OnboardingWindow.make(title: "What’s New in \(Product.name)",
                                             width: Self.width) {
            WhatsNewView(importContext: importContext,
                         onOpenSettings: { [weak self] in self?.openSettingsTapped() },
                         onLater: { [weak self] in self?.window?.close() })
        }
        win.delegate = self
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func openSettingsTapped() {
        onOpenSettings()
        window?.close()
    }

    /// One dismissal hook: however the window closes, the flag is written once and it never
    /// returns.
    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose()
    }
}

private struct WhatsNewView: View {
    let importContext: OnboardingImportContext
    let onOpenSettings: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image(nsImage: AppIconImage.shared)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text("\(Product.name) 2.0")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Your window snapping is now the Zones tool. Two new tools are available, "
                         + "off by default: Cycler and Hyperkey.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ToolTileRow()

                Text("Your shortcuts, layouts and permissions carry over unchanged.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let summary = importContext.cyclerSummary {
                    OnboardingBanner(symbol: "checkmark.circle.fill",
                                     tint: OnboardingBanner.successTint,
                                     text: summary)
                }
                if importContext.showUninstallBanner {
                    OnboardingBanner(symbol: "exclamationmark.triangle.fill",
                                     tint: .orange,
                                     text: Onboarding.cyclerUninstallBanner,
                                     actionTitle: importContext.revealCycler == nil
                                        ? nil : "Reveal Cycler in Finder",
                                     action: importContext.revealCycler)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            HStack {
                Button("Not now", action: onLater)
                Spacer()
                Button("Open Settings", action: onOpenSettings)
                    .keyboardShortcut(.defaultAction)
                    // The window's one recommended action; "Not now" stays a plain button.
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)
        }
        // A real window paints this for us; an offscreen preview render has no window, and
        // without it the whole thing composites as light text on white.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
