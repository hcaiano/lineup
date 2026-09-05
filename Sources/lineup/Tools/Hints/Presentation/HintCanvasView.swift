import AppKit
import HintsCore
import QuartzCore

/// One custom-drawn label/status canvas for one display. A single shape mask lets AppKit's system
/// material appear only beneath the compact pieces of chrome, without creating a view per hint.
@MainActor
final class HintCanvasView: NSVisualEffectView {
    private struct LabelLayout {
        var candidate: HintCanvasCandidate
        var rect: NSRect
    }

    private struct StatusLayout {
        var text: String
        var rect: NSRect
        var geometryRect: HintRect
        var tone: StatusTone
    }

    private enum StatusTone: Equatable {
        case accent
        case neutral
        case warning
    }

    private struct GridCell: Hashable {
        var column: Int
        var row: Int
    }

    /// A compact spatial index keeps dense layout linear in practice rather than comparing every
    /// label with all 1,500 possible predecessors.
    private struct CollisionGrid {
        private let cellWidth = 48.0
        private let cellHeight = 24.0
        private var buckets: [GridCell: [HintRect]] = [:]

        mutating func insert(_ rect: HintRect) {
            for cell in cells(touchedBy: rect) {
                buckets[cell, default: []].append(rect)
            }
        }

        func intersects(_ rect: HintRect) -> Bool {
            for cell in cells(touchedBy: rect) {
                if buckets[cell]?.contains(where: { $0.intersection(rect) != nil }) == true {
                    return true
                }
            }
            return false
        }

        private func cells(touchedBy rect: HintRect) -> [GridCell] {
            let minColumn = Int(floor(rect.minX / cellWidth))
            let maxColumn = Int(floor(rect.maxX / cellWidth))
            let minRow = Int(floor(rect.minY / cellHeight))
            let maxRow = Int(floor(rect.maxY / cellHeight))
            var result: [GridCell] = []
            result.reserveCapacity((maxColumn - minColumn + 1) * (maxRow - minRow + 1))
            for column in minColumn...maxColumn {
                for row in minRow...maxRow {
                    result.append(GridCell(column: column, row: row))
                }
            }
            return result
        }
    }

    let geometryBounds: HintRect
    private let safeGeometryBounds: HintRect
    private let visibleLocalFrame: NSRect
    private let fallbackScale: CGFloat
    private let materialMask = CAShapeLayer()

    private var content: HintCanvasContent?
    private var labelLayouts: [LabelLayout] = []
    private var statusLayout: StatusLayout?
    private var increaseContrast = false
    private var reduceTransparency = false

    private let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private let selectedLabelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    init(frame: NSRect, descriptor: HintPresentationScreenDescriptor) {
        geometryBounds = descriptor.geometryFrame
        safeGeometryBounds = descriptor.safeGeometryFrame
        visibleLocalFrame = descriptor.visibleLocalFrame
        fallbackScale = descriptor.backingScaleFactor
        super.init(frame: frame)

        autoresizingMask = [.width, .height]
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        materialMask.fillColor = NSColor.black.cgColor
        layer?.mask = materialMask
        setAccessibilityElement(false)
        setAccessibilityChildren([])
        refreshAccessibilityPreferences()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        rebuildLayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(_ content: HintCanvasContent) {
        self.content = content
        rebuildLayout()
    }

    func transition(to status: HintOverlayStatus) {
        guard var content else { return }
        content.status = status
        self.content = content
        rebuildLayout()
    }

    func refreshAccessibilityPreferences() {
        increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        state = reduceTransparency ? .inactive : .active
        rebuildLayout()
    }

    private var drawingScale: CGFloat {
        max(window?.backingScaleFactor ?? fallbackScale, 1)
    }

    private func rebuildLayout() {
        guard !bounds.isEmpty, let content else {
            labelLayouts = []
            statusLayout = nil
            updateMaterialMask()
            needsDisplay = true
            return
        }

        // First learn the natural dense-collision count, then reserve the resulting status chip
        // and settle once more. A final pass handles a count whose extra digit changed chip width.
        let first = layoutCandidates(content, reserving: nil)
        var status = makeStatusLayout(for: content, hiddenCount: first.hiddenCount)
        var settled = layoutCandidates(content, reserving: status?.geometryRect)
        let revisedStatus = makeStatusLayout(for: content, hiddenCount: settled.hiddenCount)
        if revisedStatus?.rect != status?.rect {
            status = revisedStatus
            settled = layoutCandidates(content, reserving: status?.geometryRect)
            status = makeStatusLayout(for: content, hiddenCount: settled.hiddenCount)
        } else {
            status = revisedStatus
        }

        labelLayouts = settled.layouts.filter { !$0.candidate.isSelected }
            + settled.layouts.filter(\.candidate.isSelected)
        statusLayout = status
        updateMaterialMask()
        needsDisplay = true
    }

    private func layoutCandidates(
        _ content: HintCanvasContent,
        reserving statusRect: HintRect?
    ) -> (layouts: [LabelLayout], hiddenCount: Int) {
        guard content.showsCandidates else { return ([], 0) }

        let selected = content.candidates.filter(\.isSelected)
        let ordinary = content.candidates.filter { !$0.isSelected }
        var grid = CollisionGrid()
        var layouts: [LabelLayout] = []
        layouts.reserveCapacity(content.candidates.count)
        var hiddenCount = 0

        // The Return target always receives first choice of its anchor. The status reserve is
        // added immediately afterwards, so ordinary labels never disappear beneath status chrome.
        for candidate in selected {
            if let layout = place(candidate, avoiding: &grid) {
                layouts.append(layout)
            } else {
                hiddenCount += 1
            }
        }
        if let statusRect { grid.insert(expanded(statusRect, by: 2)) }
        for candidate in ordinary {
            if let layout = place(candidate, avoiding: &grid) {
                layouts.append(layout)
            } else {
                hiddenCount += 1
            }
        }
        return (layouts, hiddenCount)
    }

    private func place(_ candidate: HintCanvasCandidate, avoiding grid: inout CollisionGrid) -> LabelLayout? {
        let labelLength = max(candidate.label.count, 1)
        let glyphWidth = ceil(("M" as NSString).size(withAttributes: [.font: labelFont]).width)
        let width = max(19, CGFloat(labelLength) * glyphWidth + 10)
        let height: CGFloat = 18
        guard Double(width) <= safeGeometryBounds.width, Double(height) <= safeGeometryBounds.height else {
            return nil
        }

        let frame = candidate.frame
        let anchor = HintOverlayGeometry.labelAnchor(for: frame, in: safeGeometryBounds, inset: 2)
        let w = Double(width)
        let h = Double(height)
        let gap = 3.0
        let proposals: [HintRect] = [
            HintRect(x: anchor.x, y: anchor.y, width: w, height: h),
            HintRect(x: frame.maxX - w - 2, y: frame.minY + 2, width: w, height: h),
            HintRect(x: frame.minX + 2, y: frame.maxY - h - 2, width: w, height: h),
            HintRect(x: frame.maxX - w - 2, y: frame.maxY - h - 2, width: w, height: h),
            HintRect(x: frame.minX + 2, y: frame.minY - h - gap, width: w, height: h),
            HintRect(x: frame.minX + 2, y: frame.maxY + gap, width: w, height: h),
            HintRect(x: frame.maxX + gap, y: frame.minY + 2, width: w, height: h),
            HintRect(x: frame.minX - w - gap, y: frame.minY + 2, width: w, height: h),
            HintRect(x: anchor.x + w + gap, y: anchor.y, width: w, height: h),
            HintRect(x: anchor.x, y: anchor.y + h + gap, width: w, height: h),
            HintRect(x: anchor.x - w - gap, y: anchor.y, width: w, height: h),
            HintRect(x: anchor.x, y: anchor.y - h - gap, width: w, height: h),
        ]

        var seen = Set<HintRect>()
        for proposal in proposals {
            let clamped = HintOverlayGeometry.clampedInside(proposal, in: safeGeometryBounds)
            guard clamped.width == w, clamped.height == h, seen.insert(clamped).inserted else { continue }
            let collisionRect = expanded(clamped, by: 1.5)
            guard !grid.intersects(collisionRect) else { continue }
            grid.insert(collisionRect)
            let local = HintPresentationGeometry.localRect(from: clamped, in: geometryBounds)
            return LabelLayout(
                candidate: candidate,
                rect: HintPresentationGeometry.pixelAligned(local, scale: drawingScale)
            )
        }
        return nil
    }

    private func expanded(_ rect: HintRect, by amount: Double) -> HintRect {
        HintRect(
            x: rect.minX - amount,
            y: rect.minY - amount,
            width: rect.width + amount * 2,
            height: rect.height + amount * 2
        )
    }

    private func makeStatusLayout(for content: HintCanvasContent, hiddenCount: Int) -> StatusLayout? {
        let text = statusText(for: content, hiddenCount: hiddenCount)
        guard !text.isEmpty else { return nil }
        let tone = statusTone(for: content.status)
        let measured = (text as NSString).size(withAttributes: [.font: statusFont])
        let available = visibleLocalFrame.intersection(bounds)
        let safeArea = available.isNull || available.isEmpty ? bounds.insetBy(dx: 12, dy: 12) : available
        guard safeArea.width > 24, safeArea.height > 24 else { return nil }

        let indicatorSpace: CGFloat = 14
        let width = min(max(112, ceil(measured.width) + 24 + indicatorSpace), safeArea.width - 16)
        let height: CGFloat = increaseContrast ? 29 : 27
        var rect = NSRect(
            x: safeArea.midX - width / 2,
            y: safeArea.minY + 20,
            width: width,
            height: height
        )
        if rect.maxY > safeArea.maxY - 8 { rect.origin.y = safeArea.midY - height / 2 }
        rect = HintPresentationGeometry.pixelAligned(rect, scale: drawingScale)
        return StatusLayout(
            text: text,
            rect: rect,
            geometryRect: HintPresentationGeometry.geometryRect(from: rect, in: geometryBounds),
            tone: tone
        )
    }

    private func statusText(for content: HintCanvasContent, hiddenCount: Int) -> String {
        switch content.status {
        case .scanning:
            return "Finding controls…"
        case .accessibilityBlocked:
            return "Allow Accessibility for Hints"
        case .captureUncertain:
            return "Keyboard capture unavailable"
        case .invocationFailed:
            return "Couldn’t use that control"
        case .cancelled:
            return "Hints cancelled"
        case .noMatches:
            var text: String
            switch content.mode {
            case .labels: text = "No matching hints · Backspace to widen"
            case .search: text = "No search matches · Backspace to edit"
            case .scroll: text = "No scroll areas · Space to leave"
            }
            if content.isTruncated {
                text += " · \(content.totalCandidates) available, results limited"
            }
            return text
        case .active:
            break
        }

        let query = displayQuery(content.query, uppercase: content.mode != .search)
        var parts: [String]
        switch content.mode {
        case .labels:
            parts = query.isEmpty
                ? ["\(content.visibleCount) hints"]
                : [query, "\(content.visibleCount) hints"]
        case .search:
            parts = query.isEmpty
                ? ["Search by name"]
                : ["Search \(query)", "\(content.visibleCount) matches"]
        case .scroll:
            parts = query.isEmpty
                ? ["Choose a scroll area"]
                : ["Scroll \(query)", "Arrow keys move"]
        }
        if content.isTruncated {
            parts.append("\(content.totalCandidates) available, results limited")
        }
        if hiddenCount > 0 {
            parts.append("Type to reveal \(hiddenCount) nearby labels")
        }
        return parts.joined(separator: " · ")
    }

    private func displayQuery(_ query: String, uppercase: Bool) -> String {
        let limited = query.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value != 0x7f }
            .prefix(48)
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return uppercase ? limited.uppercased() : limited
    }

    private func statusTone(for status: HintOverlayStatus) -> StatusTone {
        switch status {
        case .scanning, .active: return .accent
        case .cancelled: return .neutral
        case .noMatches, .accessibilityBlocked, .captureUncertain, .invocationFailed: return .warning
        }
    }

    private func updateMaterialMask() {
        let path = CGMutablePath()
        for layout in labelLayouts {
            path.addRoundedRect(in: layout.rect, cornerWidth: 5, cornerHeight: 5)
        }
        if let statusLayout {
            let radius = statusLayout.rect.height / 2
            path.addRoundedRect(in: statusLayout.rect, cornerWidth: radius, cornerHeight: radius)
        }
        materialMask.frame = bounds
        materialMask.path = path
        if layer?.mask !== materialMask { layer?.mask = materialMask }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bounds).addClip()
            if let statusLayout, statusLayout.rect.intersects(dirtyRect) {
                drawStatus(statusLayout)
            }
            for layout in labelLayouts where layout.rect.intersects(dirtyRect) {
                drawLabel(layout)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawLabel(_ layout: LabelLayout) {
        let selected = layout.candidate.isSelected
        let rect = layout.rect
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        (selected ? Brand.blue : neutralSurfaceColor()).setFill()
        path.fill()

        let border = selected
            ? Brand.blue
            : NSColor.separatorColor.withAlphaComponent(increaseContrast ? 0.8 : 0.42)
        border.setStroke()
        path.lineWidth = selected || increaseContrast ? 1.5 : 1 / drawingScale
        path.stroke()

        let label = layout.candidate.label.uppercased()
        let baseColor = selected
            ? NSColor.white.withAlphaComponent(0.78)
            : NSColor.labelColor.withAlphaComponent(0.9)
        let text = NSMutableAttributedString(string: label, attributes: [
            .font: selected ? selectedLabelFont : labelFont,
            .foregroundColor: baseColor,
            .kern: 0.15,
        ])
        if let content, !content.query.isEmpty, content.mode != .search {
            let prefixLength = min(content.query.count, label.count)
            let prefixColor = selected ? NSColor.white : Brand.blue
            text.addAttributes([
                .font: selectedLabelFont,
                .foregroundColor: prefixColor,
            ], range: NSRange(location: 0, length: prefixLength))
        } else if selected {
            text.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: text.length))
        }
        let size = text.size()
        let origin = NSPoint(
            x: (rect.midX - size.width / 2) * drawingScale,
            y: (rect.midY - size.height / 2 + 0.5) * drawingScale
        )
        text.draw(at: NSPoint(x: origin.x.rounded() / drawingScale, y: origin.y.rounded() / drawingScale))
    }

    private func drawStatus(_ status: StatusLayout) {
        let path = NSBezierPath(
            roundedRect: status.rect,
            xRadius: status.rect.height / 2,
            yRadius: status.rect.height / 2
        )
        neutralSurfaceColor().setFill()
        path.fill()

        let accent: NSColor
        switch status.tone {
        case .accent: accent = Brand.blue
        case .neutral: accent = .secondaryLabelColor
        case .warning: accent = .systemOrange
        }
        (status.tone == .warning
            ? accent.withAlphaComponent(increaseContrast ? 1 : 0.82)
            : NSColor.separatorColor.withAlphaComponent(increaseContrast ? 0.8 : 0.42)).setStroke()
        path.lineWidth = increaseContrast ? 2 : 1 / drawingScale
        path.stroke()

        let dotSize: CGFloat = increaseContrast ? 7 : 6
        let dot = NSRect(
            x: status.rect.minX + 11,
            y: status.rect.midY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )
        accent.setFill()
        NSBezierPath(ovalIn: dot).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: status.text, attributes: [
            .font: statusFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        attributed.draw(in: NSRect(
            x: dot.maxX + 7,
            y: status.rect.midY - 8,
            width: status.rect.maxX - dot.maxX - 16,
            height: 17
        ))
    }

    private func neutralSurfaceColor() -> NSColor {
        if reduceTransparency { return .windowBackgroundColor }
        return NSColor.controlBackgroundColor.withAlphaComponent(increaseContrast ? 0.96 : 0.82)
    }
}
