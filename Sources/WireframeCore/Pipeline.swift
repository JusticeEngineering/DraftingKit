// The makeLineDrawing pipeline (SPEC.md §4). Each stage is a separate
// internal function with its own unit tests — stages are module boundaries.
//
// M2 status: stages 4.2 (classify), 4.3 (project) and 4.7 (canonicalize) are
// live; 4.4/4.5 (visibility sampling + occlusion) arrive in M3, 4.6
// (chaining + suppression) in M4. Until M3 the public entry point runs in
// x-ray mode: every candidate edge is emitted as visible.

/// Converts a mesh + orthographic view + options into a hidden-line-removed
/// 2D line drawing. Pure function: same inputs, same output, always.
public func makeLineDrawing(mesh: Mesh,
                            view: OrthographicView,
                            options: DrawingOptions = .init()) -> LineDrawing {
    runPipeline(mesh: mesh, view: view, options: options, mode: .xray)
}

/// Internal pipeline mode. `.xray` skips occlusion and emits every candidate
/// edge as visible — used for M2 goldens and kept for debugging.
enum PipelineMode: Sendable {
    case xray
}

func runPipeline(mesh: Mesh,
                 view: OrthographicView,
                 options: DrawingOptions,
                 mode: PipelineMode) -> LineDrawing {
    // Stage 4.3a — project every vertex to (screenX, screenY, depth) and
    // measure the projected extent; sampling tolerances derive from it.
    let projected = projectPositions(mesh.positions, view: view)
    let projectedDiagonal = projectedBoundsDiagonal(projected)
    guard projectedDiagonal > 0, mesh.boundingDiagonal > 0 else {
        // Empty mesh, or the whole model projects to a single point.
        return LineDrawing(canonicalizing: [])
    }
    let tolerances = Tolerances(options: options,
                                modelDiagonal: mesh.boundingDiagonal,
                                projectedDiagonal: projectedDiagonal)

    // Stage 4.2 — per-view candidate edge classification.
    let candidates = classifyCandidateEdges(mesh: mesh, view: view, tolerances: tolerances)

    // Stage 4.3b — candidate edges as 2D segments with interpolable depth,
    // dropping those too short on screen to be lines.
    let segments = projectCandidates(candidates, mesh: mesh, projected: projected,
                                     tolerances: tolerances)

    // Stages 4.4–4.6 land in M3/M4. X-ray: every candidate is visible.
    switch mode {
    case .xray:
        let paths = segments.map {
            LineDrawing.Path(points: [SIMD2($0.start.x, $0.start.y),
                                      SIMD2($0.end.x, $0.end.y)],
                             kind: .visible)
        }
        // Stage 4.7 — canonical ordering & tight bounds.
        return LineDrawing(canonicalizing: paths)
    }
}

// MARK: Stage 4.2 — per-view edge classification

/// Why an edge is a drawing candidate (kept for tests and future styling).
enum EdgeReason: Sendable, Equatable {
    case boundary       // 1 adjacent face (or ≥3: non-manifold, always drawn)
    case crease         // dihedral angle above the crease threshold
    case silhouette     // faces flip front/back-facing across the edge
}

/// Returns (edge index, reason) for every candidate edge, in mesh.edges
/// order (already canonical — C3).
func classifyCandidateEdges(mesh: Mesh,
                            view: OrthographicView,
                            tolerances: Tolerances) -> [(edgeIndex: Int, reason: EdgeReason)] {
    var out: [(edgeIndex: Int, reason: EdgeReason)] = []
    for (index, edge) in mesh.edges.enumerated() {
        if edge.faces.count != 2 {
            // Boundary (1 face) and non-manifold (≥3) edges are always drawn.
            out.append((index, .boundary))
            continue
        }
        let n1 = mesh.faceNormals[edge.faces[0]]
        let n2 = mesh.faceNormals[edge.faces[1]]
        if dot(n1, n2) < tolerances.creaseCosineThreshold {
            out.append((index, .crease))
            continue
        }
        let s1 = signClass(dot(n1, view.forward), grazing: tolerances.grazingDot)
        let s2 = signClass(dot(n2, view.forward), grazing: tolerances.grazingDot)
        if s1 * s2 < 0 {
            out.append((index, .silhouette))
        }
    }
    return out
}

/// Sign classification with a grazing band: near-zero dots get their own
/// class (0) so grazing faces don't flip-flop between front and back facing.
@inline(__always)
func signClass(_ value: Double, grazing: Double) -> Int {
    if value > grazing { return 1 }
    if value < -grazing { return -1 }
    return 0
}

// MARK: Stage 4.3 — projection

/// A candidate edge in screen space: (x, y, depth) at both ends, depth
/// linearly interpolable along the segment.
struct ProjectedEdge: Sendable, Equatable {
    var edgeIndex: Int          // into mesh.edges
    var start: SIMD3<Double>    // (screenX, screenY, depth)
    var end: SIMD3<Double>
}

func projectPositions(_ positions: [SIMD3<Double>], view: OrthographicView) -> [SIMD3<Double>] {
    positions.map { view.project($0) }
}

/// Diagonal of the 2D bounding box of projected vertices (depth ignored).
func projectedBoundsDiagonal(_ projected: [SIMD3<Double>]) -> Double {
    guard var mn = projected.first else { return 0 }
    var mx = mn
    for p in projected {
        mn = pointwiseMin(mn, p)
        mx = pointwiseMax(mx, p)
    }
    let size = mx - mn
    return (size.x * size.x + size.y * size.y).squareRoot()
}

/// Projects candidate edges to 2D segments, dropping those whose projected
/// length is below `tolerances.minProjectedEdgeLength` (edges nearly parallel
/// to the view axis contribute dots, not lines).
func projectCandidates(_ candidates: [(edgeIndex: Int, reason: EdgeReason)],
                       mesh: Mesh,
                       projected: [SIMD3<Double>],
                       tolerances: Tolerances) -> [ProjectedEdge] {
    var out: [ProjectedEdge] = []
    out.reserveCapacity(candidates.count)
    for candidate in candidates {
        let edge = mesh.edges[candidate.edgeIndex]
        let start = projected[edge.a]
        let end = projected[edge.b]
        let dx = end.x - start.x, dy = end.y - start.y
        if (dx * dx + dy * dy).squareRoot() < tolerances.minProjectedEdgeLength { continue }
        out.append(ProjectedEdge(edgeIndex: candidate.edgeIndex, start: start, end: end))
    }
    return out
}
