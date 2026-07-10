// LineDrawing — the library's output: classified 2D polylines in model units,
// y-up, plus exact bounds over every emitted point.

/// Axis-aligned 2D rectangle (SPEC.md §3 prefers this over a tuple so
/// LineDrawing can be Codable).
public struct Rect2D: Sendable, Codable, Equatable {
    public var min: SIMD2<Double>
    public var max: SIMD2<Double>

    public init(min: SIMD2<Double>, max: SIMD2<Double>) {
        self.min = min
        self.max = max
    }

    public var size: SIMD2<Double> { max - min }

    static let zero = Rect2D(min: .zero, max: .zero)
}

public struct LineDrawing: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case visible
        case hidden
    }

    public struct Path: Sendable, Codable, Equatable {
        /// ≥ 2 points; y is UP (math convention).
        public var points: [SIMD2<Double>]
        public var kind: Kind

        public init(points: [SIMD2<Double>], kind: Kind) {
            self.points = points
            self.kind = kind
        }
    }

    public var paths: [Path]
    /// Tight bounds over every point in `paths`, in model units.
    /// `.zero` when there are no paths.
    public var bounds: Rect2D

    public init(paths: [Path], bounds: Rect2D) {
        self.paths = paths
        self.bounds = bounds
    }
}

// MARK: Canonical ordering & emit (pipeline stage 4.7)

extension LineDrawing {
    /// Builds a drawing in canonical form: each path's direction normalized
    /// (start = lexicographically smaller endpoint), paths sorted by
    /// (kind, start.x, start.y, end.x, end.y, point count) with a full
    /// lexicographic point-sequence comparison as final tiebreaker so the
    /// order is total, and bounds computed tightly from the emitted points.
    /// This ordering is what makes determinism (C3) testable.
    init(canonicalizing paths: [Path]) {
        var normalized = paths
        for i in normalized.indices {
            let pts = normalized[i].points
            if let first = pts.first, let last = pts.last, isLexicographicallySmaller(last, first) {
                normalized[i].points.reverse()
            }
        }
        normalized.sort { a, b in
            if a.kind != b.kind { return a.kind.sortRank < b.kind.sortRank }
            guard let aFirst = a.points.first, let bFirst = b.points.first else {
                return a.points.count < b.points.count
            }
            if aFirst != bFirst { return isLexicographicallySmaller(aFirst, bFirst) }
            let aLast = a.points.last!, bLast = b.points.last!
            if aLast != bLast { return isLexicographicallySmaller(aLast, bLast) }
            if a.points.count != b.points.count { return a.points.count < b.points.count }
            for (pa, pb) in zip(a.points, b.points) where pa != pb {
                return isLexicographicallySmaller(pa, pb)
            }
            return false
        }

        var bounds = Rect2D.zero
        var first = true
        for path in normalized {
            for p in path.points {
                if first {
                    bounds = Rect2D(min: p, max: p)
                    first = false
                } else {
                    bounds.min = pointwiseMin(bounds.min, p)
                    bounds.max = pointwiseMax(bounds.max, p)
                }
            }
        }
        self.init(paths: normalized, bounds: bounds)
    }
}

extension LineDrawing.Kind {
    /// visible sorts before hidden.
    var sortRank: Int {
        switch self {
        case .visible: return 0
        case .hidden: return 1
        }
    }
}

@inline(__always)
func isLexicographicallySmaller(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
    (a.x, a.y) < (b.x, b.y)
}
