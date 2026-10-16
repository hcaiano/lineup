import CoreGraphics

public enum ZoneVacancy {
    public static func isFree(_ zone: CGRect, visibleFrames: [CGRect]) -> Bool {
        !visibleFrames.contains { frame in
            let intersection = zone.intersection(frame)
            return !intersection.isNull && intersection.width > 1 && intersection.height > 1
        }
    }

    public static func destination(zones: [CGRect], filled: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        zones.filter { !$0.intersects(filled) && isFree($0, visibleFrames: visibleFrames) }.min {
            hypot($0.midX - filled.midX, $0.midY - filled.midY) < hypot($1.midX - filled.midX, $1.midY - filled.midY)
        }
    }
}

public enum ThumbnailSize {
    /// Aspect-fit within `maximum`, never larger than the source.
    public static func fit(_ source: CGSize, maximum: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 1, height: 1) }
        let ratio = min(1, maximum.width / source.width, maximum.height / source.height)
        return CGSize(width: max(1, (source.width * ratio).rounded()), height: max(1, (source.height * ratio).rounded()))
    }
}

public enum ZoneFillLayout {
    public static let thumbnail = CGSize(width: 156, height: 96)
    public static let cardHeight: CGFloat = 146
    public static let gap: CGFloat = 12
    public static let maximum = CGSize(width: 532, height: 440)
    public static let margin: CGFloat = 20
    public static let header: CGFloat = 60
    public static let inset: CGFloat = 6
    public static let bottom: CGFloat = 12

    public static func columns(panelWidth: CGFloat) -> Int {
        max(1, min(3, Int(((panelWidth - 2 * margin + gap) / (thumbnail.width + gap)).rounded(.down))))
    }

    static func width(fitting available: CGFloat) -> CGFloat {
        let count = CGFloat(columns(panelWidth: min(maximum.width, available)))
        return min(available, 2 * margin + count * thumbnail.width + (count - 1) * gap)
    }

    /// At most 532 by 440 points. When the free zone can hold one card column and one row, the
    /// chooser fits inside it, in whole columns, on the side nearest the drop. Otherwise it centers on
    /// the free zone within the display and slides off the window just placed only to a position
    /// that still overlaps the free zone.
    public static func chooserFrame(free: CGRect, filled: CGRect, visible: CGRect, rows: Int) -> CGRect {
        let bounds = visible.insetBy(dx: 12, dy: 12)
        let content = header + 2 * inset + bottom + CGFloat(rows) * cardHeight + CGFloat(max(0, rows - 1)) * gap
        let size = CGSize(width: max(1, width(fitting: bounds.width)),
                          height: max(1, min(maximum.height, bounds.height, content)))
        let inFree = free.insetBy(dx: 12, dy: 12)
        let oneColumn = 2 * margin + thumbnail.width
        let oneRow = header + 2 * inset + bottom + cardHeight
        if !inFree.isNull, inFree.width >= min(size.width, oneColumn), inFree.height >= min(size.height, oneRow) {
            let fitted = CGSize(width: min(size.width, width(fitting: inFree.width)), height: min(size.height, inFree.height))
            return CGRect(origin: CGPoint(x: filled.midX - fitted.width / 2, y: filled.midY - fitted.height / 2), size: fitted)
                .clamped(into: inFree)
        }
        let centered = CGRect(origin: CGPoint(x: free.midX - size.width / 2, y: free.midY - size.height / 2), size: size)
            .clamped(into: bounds)
        func covered(_ rect: CGRect) -> CGFloat {
            let overlap = rect.intersection(filled)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        func moved(_ rect: CGRect) -> CGFloat { hypot(rect.minX - centered.minX, rect.minY - centered.minY) }
        let clear = filled.insetBy(dx: -12, dy: -12)
        let slides = [centered.offsetBy(dx: clear.maxX - centered.minX, dy: 0),
                      centered.offsetBy(dx: clear.minX - centered.maxX, dy: 0),
                      centered.offsetBy(dx: 0, dy: clear.maxY - centered.minY),
                      centered.offsetBy(dx: 0, dy: clear.minY - centered.maxY)]
            .map { $0.clamped(into: bounds) }
            .filter { $0.intersects(free) }
        return ([centered] + slides).min { (covered($0), moved($0)) < (covered($1), moved($1)) }!
    }
}

extension CGRect {
    func clamped(into bounds: CGRect) -> CGRect {
        CGRect(x: max(bounds.minX, min(minX, bounds.maxX - width)),
               y: max(bounds.minY, min(minY, bounds.maxY - height)), width: width, height: height)
    }
}
