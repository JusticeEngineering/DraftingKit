// Chaining & coincidence suppression (pipeline stage 4.6).
//
// Chaining: within each kind, merge sub-segments that share an endpoint
// (within chainEndpointTolerance) AND are collinear into polylines, then
// collapse collinear interior points. No chaining across corners in v1 —
// every chain is therefore straight and collapses to 2 points.
//
// Suppression: drop hidden segments that coincide with a visible segment
// (both endpoints within coincidenceTolerance of its supporting line, with
// substantial projected overlap) — kills the classic cube-back-edges-under-
// front-edges dashes.

/// Chains collinear touching sub-segments into polylines, per kind.
/// Deterministic: inputs are sorted canonically first, extension candidates
/// are chosen lowest-index-first, and output order is re-canonicalized by
/// stage 4.7 afterwards.
func chainCollinearPaths(_ paths: [LineDrawing.Path],
                         tolerances: Tolerances) -> [LineDrawing.Path] {
    var out: [LineDrawing.Path] = []
    out.reserveCapacity(paths.count)
    for kind in LineDrawing.Kind.allCases {
        let segments = paths.filter { $0.kind == kind }
        out.append(contentsOf: chainOneKind(segments, kind: kind, tolerances: tolerances))
    }
    return out
}

private func chainOneKind(_ paths: [LineDrawing.Path],
                          kind: LineDrawing.Kind,
                          tolerances: Tolerances) -> [LineDrawing.Path] {
    guard paths.count > 1 else { return paths }

    // Work on straight 2-point segments in a deterministic base order.
    // (Stage 4.4 only ever emits 2-point sub-segments; anything longer is
    // passed through untouched.)
    var passthrough: [LineDrawing.Path] = []
    var segments: [(a: SIMD2<Double>, b: SIMD2<Double>)] = []
    for path in paths {
        if path.points.count == 2 {
            let p0 = path.points[0], p1 = path.points[1]
            segments.append(isLexicographicallySmaller(p0, p1) ? (p0, p1) : (p1, p0))
        } else {
            passthrough.append(path)
        }
    }
    segments.sort { lhs, rhs in
        if lhs.a != rhs.a { return isLexicographicallySmaller(lhs.a, rhs.a) }
        return isLexicographicallySmaller(lhs.b, rhs.b)
    }

    // Endpoint lookup grid, cell size = the join tolerance.
    let tolerance = tolerances.chainEndpointTolerance
    let grid = EndpointGrid(cellSize: tolerance > 0 ? tolerance : 1e-12)
    var lookup = grid.makeIndex()
    for (index, segment) in segments.enumerated() {
        grid.insert(point: segment.a, value: (index, 0), into: &lookup)
        grid.insert(point: segment.b, value: (index, 1), into: &lookup)
    }

    var used = [Bool](repeating: false, count: segments.count)
    var chains: [LineDrawing.Path] = []

    for start in segments.indices where !used[start] {
        used[start] = true
        var points = [segments[start].a, segments[start].b]

        // Grow forward from the tail, then backward from the head.
        for growingForward in [true, false] {
            while true {
                let tip = growingForward ? points[points.count - 1] : points[0]
                let inner = growingForward ? points[points.count - 2] : points[1]
                let direction = normalizedDirection(from: inner, to: tip)
                var best: (segment: Int, end: Int)? = nil
                grid.forEachNear(point: tip, in: lookup) { candidate in
                    let (index, end) = candidate
                    guard !used[index] else { return }
                    let endpoint = end == 0 ? segments[index].a : segments[index].b
                    guard length(endpoint - tip) <= tolerance else { return }
                    let far = end == 0 ? segments[index].b : segments[index].a
                    let next = normalizedDirection(from: endpoint, to: far)
                    // Must continue straight ahead: parallel and same way.
                    guard abs(cross(direction, next)) <= tolerances.chainDirectionCross,
                          dot(direction, next) > 0 else { return }
                    if best == nil || (index, end) < best! { best = (index, end) }
                }
                guard let match = best else { break }
                used[match.segment] = true
                let far = match.end == 0 ? segments[match.segment].b : segments[match.segment].a
                if growingForward {
                    points.append(far)
                } else {
                    points.insert(far, at: 0)
                }
            }
        }

        chains.append(LineDrawing.Path(
            points: collapseCollinear(points, tolerances: tolerances),
            kind: kind
        ))
    }
    return chains + passthrough
}

/// Removes interior points that deviate from the local line by less than the
/// join tolerance. Chains are straight in v1, so this normally yields the
/// two endpoints; the general form is kept for future corner-joining.
func collapseCollinear(_ points: [SIMD2<Double>], tolerances: Tolerances) -> [SIMD2<Double>] {
    guard points.count > 2 else { return points }
    var kept = [points[0]]
    for i in 1..<(points.count - 1) {
        let previous = kept[kept.count - 1]
        let next = points[i + 1]
        let base = next - previous
        let deviation = abs(cross(base, points[i] - previous))
        let baseLength = length(base)
        // Perpendicular distance of the interior point from previous→next.
        if baseLength > 0, deviation / baseLength <= tolerances.chainEndpointTolerance {
            continue
        }
        kept.append(points[i])
    }
    kept.append(points[points.count - 1])
    return kept
}

@inline(__always)
private func normalizedDirection(from a: SIMD2<Double>, to b: SIMD2<Double>) -> SIMD2<Double> {
    let d = b - a
    let len = length(d)
    return len > 0 ? d / len : .zero
}

/// Quantized 2D endpoint hash grid. Used only for candidate lookup — every
/// match is re-verified with exact distances, and candidates are visited in
/// a fixed cell order, so no hash-iteration order leaks (C3).
private struct EndpointGrid {
    typealias Value = (Int, Int)
    struct Cell: Hashable { var x: Int64, y: Int64 }
    let cellSize: Double

    func makeIndex() -> [Cell: [Value]] { [:] }

    private func cell(for p: SIMD2<Double>) -> Cell {
        Cell(x: gridCell(p.x, cellSize), y: gridCell(p.y, cellSize))
    }

    func insert(point: SIMD2<Double>, value: Value, into index: inout [Cell: [Value]]) {
        index[cell(for: point), default: []].append(value)
    }

    func forEachNear(point: SIMD2<Double>,
                     in index: [Cell: [Value]],
                     _ body: (Value) -> Void) {
        let home = cell(for: point)
        let offsets: ClosedRange<Int64> = -1...1
        for dx in offsets {
            for dy in offsets {
                guard let values = index[Cell(x: home.x &+ dx, y: home.y &+ dy)] else { continue }
                for value in values { body(value) }
            }
        }
    }
}

// MARK: Coincidence suppression

/// Drops hidden sub-segments that duplicate visible geometry: both endpoints
/// within coincidenceTolerance of a visible segment's supporting line AND
/// the projected overlap onto that segment exceeds coincidenceTolerance
/// (an overlap threshold well above bisection noise, so a hidden run that
/// merely touches a visible run's transition point survives).
func suppressHiddenCoincidentWithVisible(_ paths: [LineDrawing.Path],
                                         tolerances: Tolerances) -> [LineDrawing.Path] {
    let tolerance = tolerances.coincidenceTolerance
    // Straight visible spans (chaining has collapsed chains to 2 points;
    // longer polylines contribute their individual segments).
    var visibleSpans: [(a: SIMD2<Double>, b: SIMD2<Double>)] = []
    for path in paths where path.kind == .visible {
        for i in 0..<(path.points.count - 1) {
            visibleSpans.append((path.points[i], path.points[i + 1]))
        }
    }
    guard !visibleSpans.isEmpty else { return paths }

    let bvh = BVH(boxes: visibleSpans.map { span in
        SIMD4(Swift.min(span.a.x, span.b.x) - tolerance,
              Swift.min(span.a.y, span.b.y) - tolerance,
              Swift.max(span.a.x, span.b.x) + tolerance,
              Swift.max(span.a.y, span.b.y) + tolerance)
    })

    var candidates: [Int] = []
    return paths.filter { path in
        guard path.kind == .hidden, path.points.count == 2 else { return true }
        let p0 = path.points[0], p1 = path.points[1]
        candidates.removeAll(keepingCapacity: true)
        bvh.collectIntersecting(
            SIMD4(Swift.min(p0.x, p1.x), Swift.min(p0.y, p1.y),
                  Swift.max(p0.x, p1.x), Swift.max(p0.y, p1.y)),
            into: &candidates
        )
        for index in candidates {
            let span = visibleSpans[index]
            let axis = span.b - span.a
            let axisLength = length(axis)
            guard axisLength > 0 else { continue }
            let direction = axis / axisLength
            // Both endpoints near the supporting line?
            let d0 = abs(cross(direction, p0 - span.a))
            let d1 = abs(cross(direction, p1 - span.a))
            guard d0 <= tolerance, d1 <= tolerance else { continue }
            // Substantial overlap along the span?
            let t0 = dot(p0 - span.a, direction)
            let t1 = dot(p1 - span.a, direction)
            let overlap = Swift.min(Swift.max(t0, t1), axisLength) - Swift.max(Swift.min(t0, t1), 0)
            if overlap > tolerance { return false }
        }
        return true
    }
}
