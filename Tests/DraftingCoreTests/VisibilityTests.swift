import Foundation
import Testing
@testable import DraftingCore

@Suite("Visibility sampling & bisection (pipeline stage 4.4)")
struct VisibilityTests {

    /// Square occluder spanning x ∈ [0.25, 0.6], z ∈ [-1, 1] in the y = 0
    /// plane. Front view: occupies exactly that screen rectangle at depth 0.
    /// projectedDiagonal is pinned to 1 so s = 1/512 and t-space equals
    /// distance for a unit-length test edge.
    private func squareOccluder() -> (tester: OcclusionTester, tolerances: Tolerances) {
        var diag = MeshDiagnostics()
        let mesh = Mesh(
            weldingSoup: [
                (SIMD3(0.25, 0, -1), SIMD3(0.6, 0, -1), SIMD3(0.6, 0, 1)),
                (SIMD3(0.25, 0, -1), SIMD3(0.6, 0, 1), SIMD3(0.25, 0, 1)),
            ],
            tolerance: 1e-9,
            diagnostics: &diag
        )
        let projected = projectPositions(mesh.positions, view: .front)
        let tolerances = Tolerances(options: .init(),
                                    modelDiagonal: mesh.boundingDiagonal,
                                    projectedDiagonal: 1)
        return (OcclusionTester(mesh: mesh, projected: projected, tolerances: tolerances),
                tolerances)
    }

    @Test func transitionsAreLocalizedByBisection() {
        let (tester, tolerances) = squareOccluder()
        let edge = ProjectedEdge(edgeIndex: 0, start: SIMD3(0, 0, 5), end: SIMD3(1, 0, 5))
        let runs = visibilityRuns(for: edge, ownFaces: [], tester: tester, tolerances: tolerances)

        #expect(runs.count == 3)
        #expect(runs.map(\.hidden) == [false, true, false])
        // Unit-length edge ⇒ t equals screen distance. The occluder's
        // boundaries are at exactly 0.25 and 0.6.
        #expect(abs(runs[0].tEnd - 0.25) <= tolerances.bisectionTolerance)
        #expect(abs(runs[1].tEnd - 0.6) <= tolerances.bisectionTolerance)
        // Runs partition [0, 1] exactly.
        #expect(runs.first?.tStart == 0)
        #expect(runs.last?.tEnd == 1)
        #expect(runs[0].tEnd == runs[1].tStart)
        #expect(runs[1].tEnd == runs[2].tStart)
    }

    @Test func uniformEdgesYieldSingleRuns() {
        let (tester, tolerances) = squareOccluder()

        let clear = ProjectedEdge(edgeIndex: 0, start: SIMD3(0.7, 0, 5), end: SIMD3(1, 0, 5))
        #expect(visibilityRuns(for: clear, ownFaces: [], tester: tester, tolerances: tolerances)
            == [VisibilityRun(tStart: 0, tEnd: 1, hidden: false)])

        let covered = ProjectedEdge(edgeIndex: 0, start: SIMD3(0.3, 0, 5), end: SIMD3(0.5, 0, 5))
        #expect(visibilityRuns(for: covered, ownFaces: [], tester: tester, tolerances: tolerances)
            == [VisibilityRun(tStart: 0, tEnd: 1, hidden: true)])

        // Same screen span but IN FRONT of the occluder: fully visible.
        let inFront = ProjectedEdge(edgeIndex: 0, start: SIMD3(0.3, 0, -5), end: SIMD3(0.5, 0, -5))
        #expect(visibilityRuns(for: inFront, ownFaces: [], tester: tester, tolerances: tolerances)
            == [VisibilityRun(tStart: 0, tEnd: 1, hidden: false)])
    }

    @Test func edgesShorterThanSpacingStillGetSampled() {
        let (tester, tolerances) = squareOccluder()
        // Far shorter than s = 1/512, entirely under the occluder.
        let tiny = ProjectedEdge(edgeIndex: 0,
                                 start: SIMD3(0.4, 0, 5),
                                 end: SIMD3(0.4005, 0, 5))
        let runs = visibilityRuns(for: tiny, ownFaces: [], tester: tester, tolerances: tolerances)
        #expect(runs == [VisibilityRun(tStart: 0, tEnd: 1, hidden: true)])
    }

    @Test func depthInterpolatesAlongTheEdge() {
        let (tester, tolerances) = squareOccluder()
        // Edge dives through the occluder plane: starts 5 in front (depth
        // -5), ends 5 behind (depth +5), crossing depth 0 at t = 0.5 while
        // x = 0.45 stays under the occluder. Expect visible → hidden with
        // the transition near t = 0.5 (where interpolated depth exceeds ε).
        let diving = ProjectedEdge(edgeIndex: 0,
                                   start: SIMD3(0.45, -0.4, -5),
                                   end: SIMD3(0.45, 0.4, 5))
        let runs = visibilityRuns(for: diving, ownFaces: [], tester: tester, tolerances: tolerances)
        #expect(runs.count == 2)
        #expect(runs.map(\.hidden) == [false, true])
        let transitionT = runs[0].tEnd
        #expect(abs(transitionT - 0.5) < 0.01)
    }

    // Invariant 5: for every candidate edge of every fixture × view,
    // Σ(visible) + Σ(hidden) = projected edge length, within 2 × bisection
    // tolerance. Runs partition t ∈ [0, 1] by construction, so this also
    // guards the run assembly.
    @Test func lengthConservationAcrossFixturesAndViews() {
        let meshes = [
            Fixtures.cube(), Fixtures.cylinder(),
            Fixtures.twoOffsetBoxes(), Fixtures.lBracket(),
        ]
        let views: [OrthographicView] = [.front, .top, .right, .isometric]
        for mesh in meshes {
            for view in views {
                let projected = projectPositions(mesh.positions, view: view)
                let tolerances = Tolerances(options: .init(),
                                            modelDiagonal: mesh.boundingDiagonal,
                                            projectedDiagonal: projectedBoundsDiagonal(projected))
                let tester = OcclusionTester(mesh: mesh, projected: projected,
                                             tolerances: tolerances)
                let candidates = classifyCandidateEdges(mesh: mesh, view: view,
                                                        tolerances: tolerances)
                let segments = projectCandidates(candidates, mesh: mesh,
                                                 projected: projected, tolerances: tolerances)
                for segment in segments {
                    let runs = visibilityRuns(for: segment,
                                              ownFaces: mesh.edges[segment.edgeIndex].faces,
                                              tester: tester, tolerances: tolerances)
                    let delta = segment.end - segment.start
                    let projectedLength = (delta.x * delta.x + delta.y * delta.y).squareRoot()
                    let total = runs.reduce(0) { $0 + ($1.tEnd - $1.tStart) } * projectedLength
                    #expect(abs(total - projectedLength) <= 2 * tolerances.bisectionTolerance)
                    // Runs are contiguous, ordered, and alternate state.
                    for (a, b) in zip(runs, runs.dropFirst()) {
                        #expect(a.tEnd == b.tStart)
                        #expect(a.hidden != b.hidden)
                        #expect(a.tStart < a.tEnd)
                    }
                }
            }
        }
    }
}
