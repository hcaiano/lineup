import AppKit
import AppCore
import SwiftUI

/// First-launch welcome, for BRAND-NEW users only (`Onboarding.shouldShowWelcome`).
///
/// It runs before the system Accessibility prompt so a new user understands what Lineup is and
/// why it needs permission, instead of being dropped cold into an OS dialog for an app whose
/// window they never saw — Lineup is a menu-bar agent with no window of its own.
///
/// Rewritten for 2.0: the product is now three tools, so the window has to say what each one does
/// and which of them are off by default, and it must be explicit that Input Monitoring is NOT
/// being asked for here. An existing 1.x user never sees this window (they see What's New).
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let importContext: OnboardingImportContext
    private let onGrant: () -> Void
    private let onClose: () -> Void

    /// `onGrant` runs the Accessibility request; `onClose` fires once when the window is dismissed
    /// by any means (Grant, Not now, or the close button) so the caller can mark onboarding done.
    init(importContext: OnboardingImportContext = .none,
         onGrant: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.importContext = importContext
        self.onGrant = onGrant
        self.onClose = onClose
        super.init()
    }

    /// The welcome content as a standalone, already-sized view (offscreen preview rendering).
    static func makeEmbeddedContent() -> NSView {
        let host = NSHostingView(rootView: WelcomeView(
            importContext: OnboardingImportContext(
                cyclerSummary: "Imported 6 Cycler shortcuts and your Hyper Key setup.",
                revealCycler: {}, showUninstallBanner: true),
            onGrant: {}, onLater: {})
                .frame(width: Self.width)
                .fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        return host
    }

    private static let width: CGFloat = 520

    func show() {
        let (win, _) = OnboardingWindow.make(title: "Welcome to \(Product.name)", width: Self.width) {
            WelcomeView(importContext: importContext,
                        onGrant: { [weak self] in self?.grantTapped() },
                        onLater: { [weak self] in self?.window?.close() })
        }
        win.delegate = self
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func grantTapped() {
        onGrant()
        window?.close()
    }

    /// Single dismissal hook: whichever way the window closes, onboarding is recorded once.
    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose()
    }
}

private struct WelcomeView: View {
    let importContext: OnboardingImportContext
    let onGrant: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image(nsImage: AppIconImage.shared)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("Welcome to \(Product.name)")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Three tools for your windows and your keyboard, in one menu-bar app.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ToolTileRow()

                Divider()

                // The permission ask, in the window rather than in a bare OS sheet.
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(nsColor: Brand.blue))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(OnboardingCopy.accessibilityBody)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(OnboardingCopy.inputMonitoringNote)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

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
                    .accessibilityLabel("Continue without granting Accessibility yet")
                Spacer()
                Button("Grant Access", action: onGrant)
                    .keyboardShortcut(.defaultAction)
                    // The window's one recommended action. Two identically bordered buttons made
                    // "Not now" and "Grant Access" look like equal choices.
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

/// The running app's own icon: the bundle icon in a real `.app`, the generic executable icon
/// under `swift run`. Loaded once — both onboarding windows want it.
enum AppIconImage {
    static let shared: NSImage = {
        if let named = NSImage(named: "AppIcon") { return named }
        let path = Bundle.main.bundlePath
        if path.hasSuffix(".app") { return NSWorkspace.shared.icon(forFile: path) }
        return NSApplication.shared.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
    }()
}
