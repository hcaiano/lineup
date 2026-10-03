/// Ephemeral navigation. Hiding an extra status item never changes tool enablement.
public struct MenuPanelSession: Equatable {
    public private(set) var isOpen = false
    public private(set) var selectedTool: ToolID?
    public private(set) var visibleTools: [ToolID] = []
    private var lastTool: ToolID?

    public init() {}

    public mutating func update(runningTools: [ToolID]) {
        let running = Set(runningTools)
        // Background tools keep running; their preferences belong in Settings.
        let controls: [ToolID] = [.displayControl, .awake, .worldClock, .textCapture]
        visibleTools = controls.filter { running.contains($0) }
        if let lastTool, !visibleTools.contains(lastTool) { self.lastTool = nil }
        if isOpen, !(selectedTool.map { visibleTools.contains($0) } ?? false) {
            selectedTool = visibleTools.first
            lastTool = selectedTool
        }
    }

    public mutating func open(tool: ToolID? = nil) {
        isOpen = true
        selectedTool = tool.flatMap { visibleTools.contains($0) ? $0 : nil }
            ?? lastTool.flatMap { visibleTools.contains($0) ? $0 : nil }
            ?? visibleTools.first
        lastTool = selectedTool
    }

    public mutating func select(_ tool: ToolID) {
        guard isOpen, visibleTools.contains(tool) else { return }
        selectedTool = tool
        lastTool = tool
    }

    public mutating func moveSelection(forward: Bool) {
        guard isOpen, !visibleTools.isEmpty else { return }
        let current = selectedTool.flatMap { visibleTools.firstIndex(of: $0) } ?? 0
        select(visibleTools[(current + (forward ? 1 : visibleTools.count - 1)) % visibleTools.count])
    }

    public mutating func close() {
        isOpen = false
        selectedTool = nil
    }
}
