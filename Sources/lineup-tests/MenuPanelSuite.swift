import AppCore

func runMenuPanelTests() {
    var session = MenuPanelSession()
    let future = ToolID(rawValue: "futureTool")
    session.update(runningTools: [.zones, .worldClock, future, .displayControl, .awake, .worldClock])
    check(session.visibleTools == [.displayControl, .awake, .worldClock, .zones, future],
          "quick controls lead the panel, without duplicating tools or dropping future actions")
    session.open(tool: .worldClock)
    check(session.isOpen && session.selectedTool == .worldClock,
          "an explicit request selects the running clock in the shared panel")
    session.update(runningTools: [.zones, .displayControl, .awake])
    check(session.isOpen && session.selectedTool == .displayControl && !session.visibleTools.contains(.worldClock),
          "disabling the selected tool selects remaining controls without closing the panel")
    session.open(tool: .worldClock)
    check(session.isOpen && session.selectedTool == .displayControl,
          "a stale request falls back to an available tool")
    session.select(.awake)
    session.close()
    session.open()
    check(session.selectedTool == .awake, "reopening remembers the selected tool without persisted config")
    session.moveSelection(forward: true)
    check(session.selectedTool == .zones, "keyboard navigation reaches action tools")
    session.moveSelection(forward: true)
    check(session.selectedTool == .displayControl, "keyboard navigation wraps to the first tool")
    session.moveSelection(forward: false)
    check(session.selectedTool == .zones, "reverse navigation wraps to the last tool")
    session.select(.worldClock)
    check(session.selectedTool == .zones, "a disabled tab cannot replace the current selection")
    session.open(tool: .displayControl)
    session.close()
    session.update(runningTools: [.worldClock])
    check(!session.isOpen && session.selectedTool == nil && session.visibleTools == [.worldClock],
          "closing releases detail navigation and tool changes do not reopen the panel")
    session.open()
    check(session.selectedTool == .worldClock && session.isOpen,
          "when the remembered tool is removed, reopening selects the first visible tool")
    session.update(runningTools: [])
    check(session.selectedTool == nil && session.isOpen,
          "removing every tool leaves the open panel in its empty state")
}
