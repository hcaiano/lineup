import AppKit
import AppCore
import SwiftUI

@MainActor
final class MenuPanelModel: ObservableObject {
    @Published private(set) var session = MenuPanelSession()
    @Published private(set) var warnings: [ToolWarning] = []
    @Published private(set) var tools: [any Tool] = []

    var openSettings: () -> Void = {}
    var openToolSettings: (ToolID) -> Void = { _ in }
    var moreItems: () -> [NSMenuItem] = { [] }
    var invoke: (NSMenuItem) -> Void = { _ in }
    var close: () -> Void = {}
    var selectionChanged: () -> Void = {}

    func update(tools: [any Tool], warnings: [ToolWarning]) {
        self.tools = tools
        self.warnings = warnings
        session.update(runningTools: tools.map(\.id))
    }

    func open(tool: ToolID? = nil) { session.open(tool: tool) }
    func didClose() { session.close() }

    var orderedTools: [any Tool] {
        session.visibleTools.compactMap { id in tools.first { $0.id == id } }
    }

    func select(_ tool: ToolID) {
        session.select(tool)
        selectionChanged()
    }
    func moveSelection(forward: Bool) {
        session.moveSelection(forward: forward)
        selectionChanged()
    }

    var selectedTool: (any Tool)? {
        session.selectedTool.flatMap { id in tools.first { $0.id == id } }
    }
}

struct MenuPanel: View {
    @ObservedObject var model: MenuPanelModel
    var maximumHeight: CGFloat = 600
    @FocusState private var toolsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !model.warnings.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.warnings) { MenuPanelWarning(warning: $0) }
                    }
                    .padding(14)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 160)
                Divider()
            }
            selectedContent
                .environment(\.panelActions, panelActions)
                .frame(maxHeight: contentHeight, alignment: .top)
        }
        .frame(width: 352)
        .frame(maxHeight: maximumHeight)
        .background {
            HStack {
                ForEach(Array(model.orderedTools.enumerated()), id: \.element.id) { index, tool in
                    Button(tool.displayName) { model.select(tool.id) }
                        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command) : nil)
                }
                Button("Next tool") { model.moveSelection(forward: true) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Previous tool") { model.moveSelection(forward: false) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            .hidden()
            .accessibilityHidden(true)
        }
        .onExitCommand { model.close() }
    }

    private var contentHeight: CGFloat {
        max(100, maximumHeight - 44 - (model.warnings.isEmpty ? 0 : 160))
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            if model.orderedTools.isEmpty {
                Text("Lineup").font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 6)
            } else {
                Picker("Lineup tools", selection: Binding(get: { model.session.selectedTool },
                                                          set: { if let id = $0 { model.select(id) } })) {
                    ForEach(Array(model.orderedTools.enumerated()), id: \.element.id) { index, tool in
                        Label(tool.displayName, systemImage: tool.iconSymbol)
                            .labelStyle(.iconOnly)
                            .tag(Optional(tool.id))
                            .accessibilityValue(!tool.warnings.isEmpty ? "Needs attention" : tool.panelIsActive ? "Active" : "")
                            .help("\(tool.displayName)\(index < 9 ? " (⌘\(index + 1))" : "")")
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .focused($toolsFocused)
            }
            Spacer(minLength: 8)
            Button(action: model.openSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Open Lineup settings")
            .help("Settings (⌘,)")
            Menu {
                ForEach(Array(model.moreItems().enumerated()), id: \.offset) { _, item in
                    if item.isSeparatorItem { Divider() }
                    else {
                        Button { model.invoke(item) } label: {
                            if item.state == .on { Label(item.title, systemImage: "checkmark") }
                            else { Text(item.title) }
                        }
                        .disabled(!item.isEnabled)
                        .keyboardShortcut(item.keyEquivalent.first.map {
                            KeyboardShortcut(KeyEquivalent($0), modifiers: .command)
                        })
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More Lineup actions")
            .help("More")
        }
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lineup tools")
        .onMoveCommand { direction in
            guard toolsFocused else { return }
            if direction == .left || direction == .right {
                model.moveSelection(forward: direction == .right)
            }
        }
    }

    private var panelActions: PanelActions {
        PanelActions(
            perform: { [model] action in
                model.close()
                // Overlays and capture begin only after the popover has left the screen.
                DispatchQueue.main.async(execute: action)
            },
            openSettings: { [model] id in model.openToolSettings(id) })
    }

    @ViewBuilder
    private var selectedContent: some View {
        if let tool = model.selectedTool {
            if let full = tool.makeFullPanel(maximumHeight: contentHeight, close: model.close) {
                full.id(tool.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let controls = tool.makeQuickPanel() {
                            controls
                        } else {
                            PanelHeader(title: tool.displayName) { EmptyView() }
                            ForEach(tool.warnings) { MenuPanelWarning(warning: $0) }
                            MenuPanelActions(items: tool.menuItems(), invoke: model.invoke)
                                .padding(.horizontal, -8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: contentHeight)
                .id(tool.id)
            }
        } else {
            VStack(spacing: 8) {
                Text("No quick controls turned on").font(.headline)
                Text("Enable Display Control, Keep Awake, World Clock or Text Capture in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Settings", action: model.openSettings)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct MenuPanelWarning: View {
    let warning: ToolWarning

    var body: some View {
        PanelWarning(text: warning.text, detailLines: warning.detailLines,
                     actionTitle: warning.actionTitle, action: warning.action)
    }
}

private struct MenuPanelActions: View {
    let items: [NSMenuItem]
    let invoke: (NSMenuItem) -> Void

    var body: some View {
        let actions = items.filter { !$0.isSeparatorItem && $0.action != nil }
        // A tool with one action gets a clear button rather than a lone menu row.
        if actions.count == 1, items.allSatisfy({ $0.isSeparatorItem || $0.action != nil }), let item = actions.first {
            Button { invoke(item) } label: {
                HStack(spacing: 6) {
                    if let icon = item.image { Image(nsImage: icon) }
                    Text(item.title)
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!item.isEnabled)
            .padding(.horizontal, 8)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if !item.isSeparatorItem {
                    if item.action != nil {
                        MenuPanelActionRow(item: item, invoke: invoke)
                    } else if !item.title.isEmpty {
                        Text(item.title).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct MenuPanelActionRow: View {
    let item: NSMenuItem
    let invoke: (NSMenuItem) -> Void

    var body: some View {
        Button { invoke(item) } label: {
            HStack(spacing: 9) {
                Group {
                    if item.state == .on {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    } else if let icon = item.image {
                        Image(nsImage: icon).resizable().scaledToFit().foregroundStyle(.secondary)
                    } else {
                        Color.clear
                    }
                }.frame(width: 16, height: 16)
                Text(item.title).font(.system(size: 13))
                Spacer(minLength: 0)
                if !item.keyEquivalent.isEmpty {
                    Text("⌘" + item.keyEquivalent.uppercased())
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(PanelRowButtonStyle())
        .disabled(!item.isEnabled)
    }
}

// MARK: - Shared panel components

/// What a tab may ask of the shared panel, without widening the `Tool` contract.
struct PanelActions {
    /// Closes the panel, then runs the action: editors and captures must not open under it.
    var perform: (@escaping () -> Void) -> Void = { $0() }
    /// Opens Settings on one tool's pane.
    var openSettings: (ToolID) -> Void = { _ in }
}

private struct PanelActionsKey: EnvironmentKey {
    static let defaultValue = PanelActions()
}

extension EnvironmentValues {
    var panelActions: PanelActions {
        get { self[PanelActionsKey.self] }
        set { self[PanelActionsKey.self] = newValue }
    }
}

/// A tab's own warnings, for tabs that draw their own controls.
struct PanelWarnings: View {
    let warnings: [ToolWarning]

    var body: some View {
        ForEach(warnings) { warning in
            PanelWarning(text: warning.text, detailLines: warning.detailLines,
                         actionTitle: warning.actionTitle, action: warning.action)
        }
    }
}

/// The title row every tab starts with. The icon tabs name the tool only on hover, so the title
/// keeps the selected tab readable at a glance.
struct PanelHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory()
        }
        .frame(minHeight: 24)
    }
}

/// A calm state message with an optional recovery action. Not a warning: nothing is broken.
struct PanelNotice: View {
    let text: String
    var detail: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle {
                Button(actionTitle) { action?() }
                    .controlSize(.small)
                    .disabled(action == nil)
            }
        }
    }
}

/// An actionable problem. Orange marks it; the text stays readable in primary color.
struct PanelWarning: View {
    let text: String
    var detailLines: [String] = []
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(detailLines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Menu warnings carry their own "⚠︎" because NSMenu has no icon slot for them; the panel
    /// draws the symbol itself.
    private var message: String {
        guard text.hasPrefix("⚠︎") || text.hasPrefix("⚠") else { return text }
        return String(text.drop(while: { $0 == "⚠" || $0 == "\u{FE0E}" || $0 == "\u{FE0F}" || $0 == " " }))
    }
}

/// A full-width row that highlights under the pointer, like a menu item.
struct PanelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelRow(configuration: configuration)
    }

    private struct PanelRow: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.07 : 0))
                }
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

@MainActor
final class MenuPanelHostingController: NSHostingController<MenuPanel> {
    var onResize: ((NSSize) -> Void)?
    private var reportedSize = NSSize.zero

    override func viewDidLayout() {
        super.viewDidLayout()
        let size = view.fittingSize
        guard size.width > 0, size.height > 0, size != reportedSize else { return }
        reportedSize = size
        // Re-anchor after changes to clocks, warnings or connected displays. Otherwise a
        // growing popover can escape the visible screen or leave controls clipped.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedSize == size else { return }
            self.onResize?(size)
        }
    }
}
