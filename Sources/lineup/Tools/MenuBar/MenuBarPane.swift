import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarPane: View {
    @ObservedObject var tool: MenuBarTool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                if !tool.supported {
                    Text("Menu Bar currently supports macOS 27.").foregroundStyle(.secondary)
                }
                if let error = tool.sectionLoadError ?? tool.message {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if tool.supported {
                    if tool.settings.preferencesBookmark == nil && !tool.hasPendingRecovery {
                        SettingsSectionView("Access", caption: "Choose the Control Center settings file once so Lineup can show and hide the apps you select.") {
                            Button("Grant Access…") { tool.chooseAccess() }.disabled(!tool.canGrantAccess)
                        }
                    }
                    SettingsSectionView("Layout", caption: "Drag items to arrange them. Move an app between the two groups to choose what the arrow hides.") {
                        group("Visible Items", hidden: false)
                        group("Hidden Items", hidden: true)
                        Text("macOS hides all menu bar items from the same app together. System items stay visible.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(tool.collapsed ? "Show Hidden Items" : "Hide Selected Items") { tool.toggleVisibility() }
                            .disabled(!tool.isRunning || tool.busy || tool.settings.hiddenOwners.isEmpty)
                        Spacer()
                        Button("Refresh") { tool.refresh() }.disabled(!tool.isRunning || tool.busy)
                    }
                    Text("You can also hold Command and drag icons directly in the menu bar. Turning Menu Bar off restores the apps hidden by Lineup.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !tool.isRunning {
                        Text("Turn on Menu Bar to load the items from your running apps.").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Restore Items") { tool.restore(); tool.refresh() }.disabled(tool.busy)
                    if tool.settings.preferencesBookmark != nil || tool.hasPendingRecovery {
                        Button("Grant Access Again…") { tool.chooseAccess() }.disabled(!tool.canGrantAccess)
                    }
                }
                Button("Open macOS Menu Bar Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension*menubar")!)
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
        let members = tool.items.filter { tool.settings.hiddenOwners.contains($0.owner) == hidden }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(members) { item in
                        tile(item, hidden: hidden, members: members)
                    }
                    if members.isEmpty {
                        Text(hidden ? "Drop apps here to hide them with the arrow" : "No visible apps")
                            .font(.caption).foregroundStyle(.secondary).padding(16)
                    }
                }
                .frame(minHeight: 64)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                receive(providers) { id in
                    guard let item = tool.items.first(where: { $0.id == id }) else { return }
                    tool.setHidden(hidden, owner: item.owner)
                }
            }
            .disabled(!tool.canEdit || !tool.isRunning)
        }
    }

    private func tile(_ item: MenuBarObservedItem, hidden: Bool, members: [MenuBarObservedItem]) -> some View {
                        VStack(spacing: 4) {
                            Image(nsImage: item.icon).resizable().scaledToFit().frame(width: 24, height: 24)
                            Text(item.title).font(.caption2).lineLimit(1).frame(width: 72)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .help(item.appName + ": " + item.title)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.appName + ", " + item.title)
                        .accessibilityAction(named: Text(hidden ? "Keep visible" : "Hide with arrow")) {
                            tool.setHidden(!hidden, owner: item.owner)
                        }
                        .onDrag { NSItemProvider(object: item.id as NSString) }
                        .onDrop(of: [.plainText], isTargeted: nil) { providers in
                            receive(providers) { id in
                                if let source = tool.items.first(where: { $0.id == id }),
                                   tool.settings.hiddenOwners.contains(source.owner) != hidden {
                                    tool.setHidden(hidden, owner: source.owner)
                                } else { tool.move(id, before: item.id) }
                            }
                        }
                        .contextMenu {
                            Button(hidden ? "Keep Visible" : "Hide with Arrow") { tool.setHidden(!hidden, owner: item.owner) }
                            if let index = members.firstIndex(where: { $0.id == item.id }), index > 0 {
                                Button("Move Left") { tool.move(item.id, before: members[index - 1].id) }
                            }
                            if let index = members.firstIndex(where: { $0.id == item.id }), index + 1 < members.count {
                                Button("Move Right") { tool.move(members[index + 1].id, before: item.id) }
                            }
                        }
    }

    private func receive(_ providers: [NSItemProvider], action: @escaping (String) -> Void) -> Bool {
        guard tool.canEdit, let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let id = value as? String else { return }
            DispatchQueue.main.async { action(id) }
        }
        return true
    }
}
