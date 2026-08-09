import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Cycler's "choose an app" sheet and the app lookup behind it, extracted verbatim from
// cycler's SettingsWindow.swift so `CyclerSettingsPane.swift` is only the pane.

// MARK: - App picker sheet

struct AppPickerView: View {
    let excluding: Set<String>
    let onPick: (AppChoice?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let openNow: [AppChoice]
    private let dock: [AppChoice]

    init(excluding: Set<String>, onPick: @escaping (AppChoice?) -> Void) {
        self.excluding = excluding
        self.onPick = onPick
        let open = AppCatalog.openNow().filter { !excluding.contains($0.bundleIdentifier) }
        let openIDs = Set(open.map(\.bundleIdentifier))
        openNow = open
        dock = AppCatalog.inDock().filter { !excluding.contains($0.bundleIdentifier) && !openIDs.contains($0.bundleIdentifier) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose an App").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 16)

            List {
                section("Open Now", filtered(openNow))
                section("In Your Dock", filtered(dock))
                if filtered(openNow).isEmpty && filtered(dock).isEmpty {
                    Text(query.isEmpty ? "No apps available." : "No matches.")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                Button("Cancel") { onPick(nil); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Browse…") { browse() }
            }
            .padding(12)
        }
        .frame(width: 380, height: 480)
    }

    private func filtered(_ apps: [AppChoice]) -> [AppChoice] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder private func section(_ title: String, _ apps: [AppChoice]) -> some View {
        if !apps.isEmpty {
            Section(title) {
                ForEach(apps) { app in
                    Button { onPick(app); dismiss() } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                            Text(app.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let url = panel.url, let choice = AppCatalog.choice(forURL: url) else { return }
        if excluding.contains(choice.bundleIdentifier) { onPick(nil) } else { onPick(choice) }
        dismiss()
    }
}

// MARK: - App lookup

struct AppChoice: Identifiable {
    var bundleIdentifier: String
    var name: String
    var icon: NSImage
    var id: String { bundleIdentifier }
}

enum AppInfo {
    static func name(forBundleIdentifier id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return name(forAppURL: url) ?? id
    }
    static func name(forAppURL url: URL) -> String? {
        if let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let v = bundle.object(forInfoDictionaryKey: key) as? String, !v.isEmpty { return v }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
    static func icon(forBundleIdentifier id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum AppCatalog {
    static func openNow() -> [AppChoice] {
        sortByName(dedup(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
                return AppChoice(bundleIdentifier: id,
                                 name: AppInfo.name(forAppURL: url) ?? app.localizedName ?? id,
                                 icon: NSWorkspace.shared.icon(forFile: url.path))
            }))
    }
    static func inDock() -> [AppChoice] {
        sortByName(dedup(dockURLs().compactMap(choice(forURL:))))
    }
    static func choice(forURL url: URL) -> AppChoice? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        return AppChoice(bundleIdentifier: id,
                         name: AppInfo.name(forAppURL: url) ?? id,
                         icon: NSWorkspace.shared.icon(forFile: url.path))
    }
    private static func dockURLs() -> [URL] {
        guard let apps = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") else { return [] }
        return apps.compactMap { item in
            guard let d = item as? [String: Any], let t = d["tile-data"] as? [String: Any],
                  let f = t["file-data"] as? [String: Any], let raw = f["_CFURLString"] as? String,
                  let url = URL(string: raw), url.isFileURL else { return nil }
            return url
        }
    }
    private static func dedup(_ c: [AppChoice]) -> [AppChoice] {
        var seen = Set<String>(); var out: [AppChoice] = []
        for x in c where !seen.contains(x.bundleIdentifier) { seen.insert(x.bundleIdentifier); out.append(x) }
        return out
    }
    private static func sortByName(_ c: [AppChoice]) -> [AppChoice] {
        c.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
