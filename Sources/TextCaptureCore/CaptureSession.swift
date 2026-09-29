import Foundation
import CoreGraphics

/// The clipboard commit gate. Every callback carries its invocation token, including failures.
/// Cancellation invalidates it before any operating-system work is torn down.
public struct CaptureSession {
    public enum Outcome: Equatable {
        case copy(String)
        case empty
        case failed
        case ignored
    }

    public private(set) var token: UUID?
    public var isActive: Bool { token != nil }

    public init() {}

    public mutating func begin() -> UUID? {
        guard token == nil else { return nil }
        let next = UUID()
        token = next
        return next
    }

    public mutating func cancel() { token = nil }

    public mutating func finish(_ invocation: UUID, text: String?) -> Outcome {
        guard token == invocation else { return .ignored }
        token = nil
        guard let text else { return .failed }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .empty : .copy(trimmed)
    }
}

public struct RecognizedLine {
    public let text: String
    /// Vision's normalized, bottom-left coordinates.
    public let bounds: CGRect

    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

public enum CaptureText {
    /// Group fragments on the same baseline, then read each row from left to right. Sorting
    /// with a fuzzy y comparator is not transitive, so row grouping happens after a strict sort.
    public static func readingOrder(_ observations: [RecognizedLine]) -> String {
        let lines = observations.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.bounds.isEmpty
        }.sorted {
            if $0.bounds.maxY != $1.bounds.maxY { return $0.bounds.maxY > $1.bounds.maxY }
            return $0.bounds.minX < $1.bounds.minX
        }
        var rows: [[RecognizedLine]] = []
        for line in lines {
            if let index = rows.firstIndex(where: { row in
                let anchor = row[0].bounds
                let overlap = min(anchor.maxY, line.bounds.maxY) - max(anchor.minY, line.bounds.minY)
                return overlap >= min(anchor.height, line.bounds.height) * 0.5
            }) {
                rows[index].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            row.sorted { $0.bounds.minX < $1.bounds.minX }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// Prefer Portuguese and English variants actually installed in the local Vision engine.
    /// An absent language is reported explicitly by the UI rather than silently substituted.
    public static func languages(available: [String]) -> (selected: [String], missing: [String]) {
        var selected: [String] = []
        var missing: [String] = []
        for (prefix, name) in [("pt", "Portuguese"), ("en", "English")] {
            if let match = available.first(where: { $0 == prefix || $0.hasPrefix(prefix + "-") }) {
                selected.append(match)
            } else {
                missing.append(name)
            }
        }
        return (selected, missing)
    }
}
