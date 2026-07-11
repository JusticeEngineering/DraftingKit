// The makeLineDrawing pipeline (SPEC.md §4). Each stage is a separate
// internal function with its own unit tests — stages are module boundaries.
//
// All seven stages are live as of M4. Execution: the synchronous entry point
// runs the per-edge visibility work serially; the async overload fans it out
// over a TaskGroup in edge-index chunks, writing into an index-addressed
// results array (constraint C3) — both produce byte-identical output
// (invariant 6).

/// Converts a mesh + orthographic view + options into a hidden-line-removed
/// 2D line drawing. Pure function: same inputs, same output, always.
///
/// This synchronous form computes serially. In an async context, prefer
/// `await makeLineDrawing(...)`, which parallelizes the visibility sampling
/// and returns bit-identical results.
public func makeLineDrawing(mesh: Mesh,
                            view: OrthographicView,
                            options: DrawingOptions = .init()) -> LineDrawing {
    runPipeline(mesh: mesh, view: view, options: options, mode: .full)
}

/// Parallel variant: identical output to the synchronous form (deterministic
/// by construction), computed via a TaskGroup over edge chunks.
///
/// Every stage — including the serial ones (projection, BVH build, chaining)
/// — runs inside child tasks on the global executor, so calling this from
/// the main actor never blocks UI no matter how heavy the mesh is.
public func makeLineDrawing(mesh: Mesh,
                            view: OrthographicView,
                            options: DrawingOptions = .init()) async -> LineDrawing {
    await withTaskGroup(of: LineDrawing.self) { group in
        group.addTask {
            guard let scene = prepareScene(mesh: mesh, view: view, options: options) else {
                return LineDrawing(canonicalizing: [])
            }
            let tester = OcclusionTester(mesh: mesh, projected: scene.projected,
                                         tolerances: scene.tolerances)
            let runs = await computeRunsParallel(scene: scene, tester: tester)
            return finishFullDrawing(runsPerSegment: runs, scene: scene)
        }
        // Exactly one child task.
        return await group.next() ?? LineDrawing(canonicalizing: [])
    }
}

/// Internal pipeline mode. `.xray` skips occlusion and emits every candidate
/// edge as visible — kept for debugging and stage-isolated tests.
enum PipelineMode: Sendable {
    case xray
    case full
}

/// Synchronous (serial) pipeline — also the reference for invariant 6.
func runPipeline(mesh: Mesh,
                 view: OrthographicView,
                 options: DrawingOptions,
                 mode: PipelineMode) -> LineDrawing {
    guard let scene = prepareScene(mesh: mesh, view: view, options: options) else {
        return LineDrawing(canonicalizing: [])
    }
    switch mode {
    case .xray:
        // Occlusion skipped: every candidate emitted visible, whole.
        let paths = scene.segments.map {
            LineDrawing.Path(points: [SIMD2($0.start.x, $0.start.y),
                                      SIMD2($0.end.x, $0.end.y)],
                             kind: .visible)
        }
        return LineDrawing(canonicalizing: paths)

    case .full:
        let tester = OcclusionTester(mesh: mesh, projected: scene.projected,
                                     tolerances: scene.tolerances)
        let runs = computeRunsSerial(scene: scene, tester: tester)
        return finishFullDrawing(runsPerSegment: runs, scene: scene)
    }
}

// MARK: Scene preparation (stages 4.2 + 4.3)

/// Everything the per-edge visibility stage needs, prepared once per call.
/// Sendable: shared read-only across the TaskGroup.
struct PreparedScene: Sendable {
    var mesh: Mesh
    var options: DrawingOptions
    var tolerances: Tolerances
    var projected: [SIMD3<Double>]
    var segments: [ProjectedEdge]
}

/// Runs projection (4.3) and classification (4.2). Returns nil when there is
/// nothing to draw (empty mesh or a projection collapsed to a single point).
func prepareScene(mesh: Mesh,
                  view: OrthographicView,
                  options: DrawingOptions) -> PreparedScene? {
    let projected = projectPositions(mesh.positions, view: view)
    let projectedDiagonal = projectedBoundsDiagonal(projected)
    guard projectedDiagonal > 0, mesh.boundingDiagonal > 0 else { return nil }
    let tolerances = Tolerances(options: options,
                                modelDiagonal: mesh.boundingDiagonal,
                                projectedDiagonal: projectedDiagonal)
    let candidates = classifyCandidateEdges(mesh: mesh, view: view, tolerances: tolerances)
    let segments = projectCandidates(candidates, mesh: mesh, projected: projected,
                                     tolerances: tolerances)
    return PreparedScene(mesh: mesh, options: options, tolerances: tolerances,
                         projected: projected, segments: segments)
}

// MARK: Per-edge visibility (stages 4.4 + 4.5), serial and parallel

private func computeRunsChunk(_ range: Range<Int>,
                              scene: PreparedScene,
                              tester: OcclusionTester) -> [[VisibilityRun]] {
    var chunk: [[VisibilityRun]] = []
    chunk.reserveCapacity(range.count)
    for index in range {
        let segment = scene.segments[index]
        chunk.append(visibilityRuns(for: segment,
                                    ownFaces: scene.mesh.edges[segment.edgeIndex].faces,
                                    tester: tester,
                                    tolerances: scene.tolerances))
    }
    return chunk
}

func computeRunsSerial(scene: PreparedScene, tester: OcclusionTester) -> [[VisibilityRun]] {
    computeRunsChunk(scene.segments.indices, scene: scene, tester: tester)
}

/// TaskGroup over fixed edge-index chunks. Chunk results carry their offset
/// and land in a preallocated index-addressed array, so completion order
/// cannot influence output (constraint C3).
func computeRunsParallel(scene: PreparedScene,
                         tester: OcclusionTester) async -> [[VisibilityRun]] {
    let count = scene.segments.count
    guard count > 0 else { return [] }
    // Fixed fan-out; the cooperative pool schedules chunks onto cores.
    let chunkSize = Swift.max(1, (count + 63) / 64)
    var results = [[VisibilityRun]?](repeating: nil, count: count)
    await withTaskGroup(of: (Int, [[VisibilityRun]]).self) { group in
        var start = 0
        while start < count {
            let range = start..<Swift.min(start + chunkSize, count)
            group.addTask {
                (range.lowerBound, computeRunsChunk(range, scene: scene, tester: tester))
            }
            start = range.upperBound
        }
        for await (offset, chunk) in group {
            for (i, runs) in chunk.enumerated() {
                results[offset + i] = runs
            }
        }
    }
    return results.map { $0! }
}

// MARK: Emit + finish (stages 4.6 + 4.7)

func finishFullDrawing(runsPerSegment: [[VisibilityRun]],
                       scene: PreparedScene) -> LineDrawing {
    var paths: [LineDrawing.Path] = []
    for (index, runs) in runsPerSegment.enumerated() {
        let segment = scene.segments[index]
        for run in runs {
            if run.hidden && !scene.options.includeHiddenLines { continue }
            paths.append(LineDrawing.Path(
                points: [segment.point(at: run.tStart), segment.point(at: run.tEnd)],
                kind: run.hidden ? .hidden : .visible
            ))
        }
    }
    // Stage 4.6 — collinear chaining, then coincidence suppression.
    paths = chainCollinearPaths(paths, tolerances: scene.tolerances)
    if scene.options.suppressHiddenCoincidentWithVisible && scene.options.includeHiddenLines {
        paths = suppressHiddenCoincidentWithVisible(paths, tolerances: scene.tolerances)
    }
    // Stage 4.7 — canonical ordering & tight bounds.
    return LineDrawing(canonicalizing: paths)
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

    /// 2D point at parameter t along the segment; bitwise-exact endpoints at
    /// t = 0 and t = 1 (fully-visible edges emit their exact projections).
    func point(at t: Double) -> SIMD2<Double> {
        if t == 0 { return SIMD2(start.x, start.y) }
        if t == 1 { return SIMD2(end.x, end.y) }
        let p = start + t * (end - start)
        return SIMD2(p.x, p.y)
    }
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

/// Projects candidate edges to 2D segments, dropping foreshortened ones:
/// short on screen AND much shorter than their 3D length (nearly parallel to
/// the view axis — dots, not lines). Edges that are short simply because the
/// tessellation is fine project at ratio ≈ 1 and are kept, so finely
/// tessellated models keep their outlines.
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
        let projectedLength = (dx * dx + dy * dy).squareRoot()
        if projectedLength < tolerances.minProjectedEdgeLength {
            let length3D = length(mesh.positions[edge.b] - mesh.positions[edge.a])
            if projectedLength < tolerances.foreshorteningRatio * length3D { continue }
        }
        out.append(ProjectedEdge(edgeIndex: candidate.edgeIndex, start: start, end: end))
    }
    return out
}
