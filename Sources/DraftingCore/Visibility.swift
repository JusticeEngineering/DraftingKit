// Visibility sampling (pipeline stage 4.4): the Appel insight implemented by
// sampling — visibility along an edge changes only at a finite set of points,
// so sample at sub-interval midpoints (sidestepping endpoint-on-vertex
// degeneracies), then bisect between disagreeing neighbors until the
// transition is localized within `bisectionTolerance`.

/// A maximal run of constant visibility along a projected edge,
/// parameterized by t ∈ [0, 1] from segment start to end. Runs partition
/// [0, 1] exactly, which is what makes length conservation (invariant 5)
/// hold by construction.
struct VisibilityRun: Sendable, Equatable {
    var tStart: Double
    var tEnd: Double
    var hidden: Bool
}

/// Samples one projected candidate edge against the occluders and returns
/// its visibility runs in ascending t order.
func visibilityRuns(for segment: ProjectedEdge,
                    ownFaces: [Int],
                    tester: OcclusionTester,
                    tolerances: Tolerances) -> [VisibilityRun] {
    let delta = segment.end - segment.start
    let projectedLength = (delta.x * delta.x + delta.y * delta.y).squareRoot()

    @inline(__always)
    func hidden(at t: Double) -> Bool {
        tester.isHidden(segment.start + t * delta, ownFaces: ownFaces)
    }

    // Sub-interval midpoints at spacing ≤ sampleSpacing, minimum 2 samples.
    let intervals = Swift.max(2, ceilToInt(projectedLength / tolerances.sampleSpacing))
    var states = [Bool]()
    states.reserveCapacity(intervals)
    for i in 0..<intervals {
        states.append(hidden(at: (Double(i) + 0.5) / Double(intervals)))
    }

    // Bisect every state change to a crisp transition point.
    var runs: [VisibilityRun] = []
    var runStart = 0.0
    var runState = states[0]
    let tTolerance = projectedLength > 0
        ? tolerances.bisectionTolerance / projectedLength
        : 1.0
    for i in 1..<intervals where states[i] != states[i - 1] {
        var lo = (Double(i - 1) + 0.5) / Double(intervals)  // state == states[i-1]
        var hi = (Double(i) + 0.5) / Double(intervals)      // state == states[i]
        while hi - lo > tTolerance {
            let mid = (lo + hi) / 2
            if hidden(at: mid) == states[i - 1] {
                lo = mid
            } else {
                hi = mid
            }
        }
        let transition = (lo + hi) / 2
        runs.append(VisibilityRun(tStart: runStart, tEnd: transition, hidden: runState))
        runStart = transition
        runState = states[i]
    }
    runs.append(VisibilityRun(tStart: runStart, tEnd: 1, hidden: runState))
    return runs
}
