import AppCore

func runMenuPanelTests() {
    var session = MenuPanelSession()
    let future = ToolID(rawValue: "futureTool")
    session.update(runningTools: ToolID.all + [future, .worldClock])
    check(session.visibleTools == [.displayControl, .awake, .worldClock, .textCapture],
          "only enabled quick controls appear, once each, even with every background tool running")
    session.open(tool: .worldClock)
    check(session.isOpen && session.selectedTool == .worldClock,
          "an explicit request selects the running clock in the shared panel")
    session.update(runningTools: [.zones, .cycler, .displayControl, .awake, .textCapture])
    check(session.isOpen && session.selectedTool == .displayControl && !session.visibleTools.contains(.worldClock),
          "disabling the selected tool selects remaining controls without closing the panel")
    session.open(tool: .worldClock)
    check(session.isOpen && session.selectedTool == .displayControl,
          "a stale request falls back to an available tool")
    session.select(.awake)
    session.close()
    session.open()
    check(session.selectedTool == .awake, "reopening remembers the selected tool without persisted config")
    session.open(tool: .cycler)
    check(session.selectedTool == .awake,
          "requesting a running background tool keeps an available quick control selected")
    session.moveSelection(forward: true)
    check(session.selectedTool == .textCapture, "keyboard navigation reaches capture controls")
    session.moveSelection(forward: true)
    check(session.selectedTool == .displayControl, "keyboard navigation wraps to the first tool")
    session.moveSelection(forward: false)
    check(session.selectedTool == .textCapture, "reverse navigation wraps to the last quick control")
    session.select(.worldClock)
    session.select(.zones)
    check(session.selectedTool == .textCapture,
          "disabled quick controls and running background tools cannot replace the current selection")
    session.open(tool: .displayControl)
    session.close()
    session.update(runningTools: [.worldClock])
    check(!session.isOpen && session.selectedTool == nil && session.visibleTools == [.worldClock],
          "closing releases detail navigation and tool changes do not reopen the panel")
    session.open()
    check(session.selectedTool == .worldClock && session.isOpen,
          "when the remembered tool is removed, reopening selects the first visible tool")
    session.update(runningTools: [.zones, .cycler, .hyperkey, .keyboardRemap, .menuBar, .scroll, future])
    check(session.selectedTool == nil && session.visibleTools.isEmpty && session.isOpen,
          "disabling the last quick control clears its selection while background tools keep running")
    session.close()
    session.open(tool: .hyperkey)
    session.moveSelection(forward: true)
    session.moveSelection(forward: false)
    check(session.selectedTool == nil && session.isOpen,
          "opening and navigating with background tools alone keeps the panel in its empty state")
    session.update(runningTools: [.hyperkey, .textCapture])
    check(session.selectedTool == .textCapture,
          "enabling a quick control while the empty panel is open selects it")
    session.update(runningTools: [])
    check(session.selectedTool == nil && session.visibleTools.isEmpty && session.isOpen,
          "stopping every tool leaves the open panel in its empty state")
}
