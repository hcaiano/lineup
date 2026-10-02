import AppCore
import AppKit
import SwiftUI

/// Shows the two groups as the menu bar arranges them. Arranging happens in the menu bar
/// itself with Command-drag; Lineup never moves icons or the pointer.
struct MenuBarPane: View {
    @ObservedObject var tool: MenuBarTool

    private struct App: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        let running: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                if !tool.supported {
                    Text("Menu Bar currently supports macOS 27.").foregroundStyle(.secondary)
                } else if !tool.available {
                    BlockedBanner(message: MenuBarTool.unavailableText, systemImage: "exclamationmark.triangle.fill")
                }
                if let error = tool.sectionLoadError ?? tool.message {
                    BlockedBanner(message: error, systemImage: "exclamationmark.triangle.fill")
                }
                if tool.hasPendingRecovery {
                    SettingsSectionView("Recovery", caption: "Some hidden icons could not be restored. Restore them before hiding another group.") {
                        HStack {
                            Button("Restore Icons") { tool.restoreIcons() }
                            Button("Grant Access…") { tool.chooseAccess() }
                        }
                    }
                }
                if tool.supported && tool.available {
                    if tool.settings.preferencesBookmark == nil && !tool.hasPendingRecovery {
                        SettingsSectionView("One-time setup", caption: "Allow Lineup to show and hide the apps you choose.") {
                            HStack {
                                Button("Allow Menu Bar Access…") { tool.chooseAccess() }
                                    .disabled(tool.busy)
                                Spacer()
                            }
                        }
                    }
                    SettingsSectionView("Your menu bar", caption: "Hold ⌘ Command and drag icons in the menu bar. Left of the arrow hides; right stays visible.") {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text(!tool.isRunning ? "Turn on Menu Bar to add the arrow."
                                     : tool.collapsed ? "Hidden icons are tucked away." : "Hidden icons are showing.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                if tool.settings.preferencesBookmark != nil {
                                    Button(tool.collapsed ? "Show Icons" : "Hide Icons") { tool.toggleVisibility() }
                                        .keyboardShortcut(.defaultAction)
                                        .disabled(!tool.isRunning || tool.busy || tool.hasPendingRecovery)
                                }
                            }
                            group("Hidden by the arrow", hidden: true)
                            group("Always visible", hidden: false)
                            SettingsCaption(text: "Click the arrow to show hidden icons for \(Int(MenuBarAutoHide.delay)) seconds. They stay visible while you use their menus.")
                        }
                    }
                    DisclosureGroup("More options") {
                        VStack(alignment: .leading, spacing: 10) {
                            SettingsCaption(text: "macOS groups all icons from the same app. If an app has an icon on each side of the arrow, it stays visible.")
                            SettingsCaption(text: "The clock, Control Center and recording indicators always stay visible.")
                            if tool.settings.preferencesBookmark != nil {
                                Button("Allow Menu Bar Access Again…") { tool.chooseAccess() }
                                    .disabled(tool.busy)
                            }
                            Button("Open macOS Menu Bar Settings…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension*menubar")!)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
            .padding(.vertical, SettingsMetrics.panePaddingVertical)
            .frame(maxWidth: .infinity)
        }
        .onAppear { tool.setPaneVisible(true) }
        .onDisappear { tool.setPaneVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.delegate is SettingsWindowController {
                tool.setPaneVisible(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if (notification.object as? NSWindow)?.delegate is SettingsWindowController {
                tool.setPaneVisible(true)
            }
        }
    }

    private func group(_ title: String, hidden: Bool) -> some View {
        let members = apps(hidden: hidden)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(hidden ? "Left of the arrow" : "Right of the arrow")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(members) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon).resizable().scaledToFit().frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        Text(app.name).lineLimit(1).help(app.name)
                        Spacer()
                        if !app.running {
                            Text("Not running").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
                if members.isEmpty {
                    Text(hidden ? "Move an icon left of the arrow to hide it."
                         : tool.isRunning ? "No apps on this side of the arrow." : "Apps appear here when Menu Bar is on.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
        }
    }

    /// macOS changes visibility per app, so show one named row even for apps with several icons.
    private func apps(hidden: Bool) -> [App] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var result: [App] = []
        for item in tool.items where tool.hiddenGroup.contains(item.owner) == hidden {
            guard !result.contains(where: { $0.id == item.owner }) else { continue }
            result.append(App(id: item.owner, name: item.appName, icon: item.icon, running: running.contains(item.owner)))
        }
        if hidden {
            for app in tool.offscreenHiddenApps where !result.contains(where: { $0.id == app.owner }) {
                result.append(App(id: app.owner, name: app.name, icon: app.icon, running: running.contains(app.owner)))
            }
        }
        return result
    }
}
