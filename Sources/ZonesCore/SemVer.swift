import Foundation

/// Tiny semantic-version comparator for release tags. Accepts plain versions
/// (`1.2.3`) and tags with a leading `v` (`v1.2.3`).
public enum SemVer {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let lhs = parse(candidate), let rhs = parse(current) else { return false }
        return lhs.lexicographicallyPrecedes(rhs) == false && lhs != rhs
    }

    private static func parse(_ raw: String) -> [Int]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        guard !s.isEmpty else { return nil }

        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        while out.count < 3 { out.append(0) }
        return out
    }
}
