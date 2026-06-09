import CoreGraphics
import Foundation

/// How a horizontal position value is interpreted.
public enum Unit: String, Codable {
    case fraction   // 0...1 of the display's width
    case points     // AppKit points from the display's left edge
    case pixels     // physical pixels from the left edge (converted via display scale)
}

/// A horizontal position on the display (a divider line or a split point).
public struct Boundary: Codable, Equatable {
    public var value: Double
    public var unit: Unit

    public init(_ value: Double, _ unit: Unit) {
        self.value = value
        self.unit = unit
    }

    /// Resolve to an absolute Cocoa-space x (points), anchored at `frame.minX`.
    /// `pixelsWide` is the display's physical width (CGDisplayPixelsWide); only used
    /// for `.pixels`. Layout math stays in points everywhere else.
    public func x(in frame: CGRect, pixelsWide: Int) -> CGFloat {
        switch unit {
        case .fraction:
            return frame.minX + CGFloat(value) * frame.width
        case .points:
            return frame.minX + CGFloat(value)
        case .pixels:
            let scale = pixelsWide > 0 ? frame.width / CGFloat(pixelsWide) : 1
            return frame.minX + CGFloat(value) * scale
        }
    }
}

/// The whole layout, defined by SHARED divider lines so columns can never gap or overlap.
///
/// You set where the dividers go (one entry per line between columns). The columns are
/// simply the regions between the screen edges and those dividers, so each column's right
/// edge *is* the next column's left edge. Move one divider and both neighbouring columns
/// adapt together — no second number to keep in sync.
///
/// `N` dividers produce `N+1` columns. For the G9 three-way split, give two dividers.
/// Horizontal extent comes from the full `screen.frame` (so it lands on physical seams);
/// vertical extent fills the usable `visibleFrame` (never under the menu bar / Dock).
public struct ColumnConfig: Codable, Equatable {
    /// The lines between columns, left to right. Two dividers => three columns.
    public var dividers: [Boundary]
    /// Where `Hyper + [` / `Hyper + ]` split the screen (defaults to the exact middle).
    public var halfDivider: Boundary

    public init(dividers: [Boundary], halfDivider: Boundary) {
        self.dividers = dividers
        self.halfDivider = halfDivider
    }

    /// Default: equal thirds, halves at the middle. Tune the dividers to your seams.
    public static let `default` = ColumnConfig(
        dividers: [Boundary(1.0 / 3.0, .fraction), Boundary(2.0 / 3.0, .fraction)],
        halfDivider: Boundary(0.5, .fraction))

    /// Column rects, left to right — always gapless: column[i].maxX == column[i+1].minX.
    public func columns(frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) -> [CGRect] {
        // Resolve, clamp into the display, and sort so out-of-order config still tiles.
        let xs = dividers
            .map { $0.x(in: frame, pixelsWide: pixelsWide) }
            .map { Swift.min(Swift.max($0, frame.minX), frame.maxX) }
            .sorted()
        let edges = [frame.minX] + xs + [frame.maxX]
        var rects: [CGRect] = []
        for i in 0..<(edges.count - 1) {
            rects.append(CGRect(
                x: edges[i],
                y: visibleFrame.minY,
                width: edges[i + 1] - edges[i],
                height: visibleFrame.height))
        }
        return rects
    }

    /// Resolve a binding id ("full"/"left"/"center"/"right"/"leftHalf"/"rightHalf").
    public func rect(for id: String, frame: CGRect, visibleFrame: CGRect, pixelsWide: Int) -> CGRect? {
        let full = CGRect(
            x: frame.minX, y: visibleFrame.minY,
            width: frame.width, height: visibleFrame.height)

        switch id {
        case "full":
            return full
        case "left":
            return columns(frame: frame, visibleFrame: visibleFrame, pixelsWide: pixelsWide).first
        case "right":
            return columns(frame: frame, visibleFrame: visibleFrame, pixelsWide: pixelsWide).last
        case "center":
            let cols = columns(frame: frame, visibleFrame: visibleFrame, pixelsWide: pixelsWide)
            return cols.isEmpty ? nil : cols[cols.count / 2] // middle column (3 cols -> idx 1)
        case "leftHalf":
            let hx = halfDivider.x(in: frame, pixelsWide: pixelsWide)
            return CGRect(x: frame.minX, y: visibleFrame.minY,
                          width: hx - frame.minX, height: visibleFrame.height)
        case "rightHalf":
            let hx = halfDivider.x(in: frame, pixelsWide: pixelsWide)
            return CGRect(x: hx, y: visibleFrame.minY,
                          width: frame.maxX - hx, height: visibleFrame.height)
        default:
            return nil
        }
    }

    /// Load from JSON at `url`, falling back to `.default` if the file is absent.
    /// Throws only on a present-but-malformed file.
    public static func load(from url: URL) throws -> ColumnConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ColumnConfig.self, from: data)
    }

    /// Write to JSON at `url`, creating parent directories as needed (atomic).
    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Build a pixel-unit config from divider positions measured in physical pixels from
    /// the display's left edge. `halfPixels` is the split for Hyper+[ / Hyper+].
    public static func fromPixels(dividers: [Double], halfPixels: Double) -> ColumnConfig {
        ColumnConfig(
            dividers: dividers.sorted().map { Boundary($0, .pixels) },
            halfDivider: Boundary(halfPixels, .pixels))
    }

    /// Sanitize raw pixel divider positions: clamp into `0...pixelsWide`, sort, and keep
    /// every column (including the two outer ones) at least `minColumn` pixels wide, so a
    /// user can't save a zero-width column. Pure so it's unit-tested.
    public static func clampPixelDividers(_ xs: [Double], pixelsWide: Int, minColumn: Double) -> [Double] {
        let maxX = Double(pixelsWide)
        let sorted = xs.map { Swift.min(Swift.max($0, 0), maxX) }.sorted()
        var out: [Double] = []
        var lower = minColumn
        for (i, x) in sorted.enumerated() {
            let remaining = Double(sorted.count - i - 1)
            let upper = maxX - minColumn * (remaining + 1)
            out.append(Swift.min(Swift.max(x, lower), Swift.max(lower, upper)))
            lower = out[i] + minColumn
        }
        return out
    }
}
