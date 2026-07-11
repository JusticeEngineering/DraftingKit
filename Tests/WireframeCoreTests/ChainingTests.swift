import Foundation
import Testing
@testable import WireframeCore

@Suite("Chaining & coincidence suppression (pipeline stage 4.6)")
struct ChainingTests {

    /// s = 1/512, so chain tolerance = s/16 ≈ 1.22e-4 and coincidence
    /// tolerance = s/4 ≈ 4.88e-4.
    private var tolerances: Tolerances {
        Tolerances(options: .init(), modelDiagonal: 1, projectedDiagonal: 1)
    }

    private func seg(_ a: (Double, Double), _ b: (Double, Double),
                     _ kind: LineDrawing.Kind = .visible) -> LineDrawing.Path {
        LineDrawing.Path(points: [SIMD2(a.0, a.1), SIMD2(b.0, b.1)], kind: kind)
    }

    // MARK: Chaining

    @Test func collinearRunMergesIntoOnePath() {
        // Shuffled order and mixed orientations must not matter.
        let input = [
            seg((2, 0), (1, 0)),
            seg((0, 0), (1, 0)),
            seg((3, 0), (2, 0)),
        ]
        let chained = chainCollinearPaths(input, tolerances: tolerances)
        #expect(chained.count == 1)
        #expect(chained[0].points.count == 2, "collinear interior points collapse")
        #expect(Set(chained[0].points) == [SIMD2(0, 0), SIMD2(3, 0)])
    }

    @Test func cornersDoNotChain() {
        let chained = chainCollinearPaths(
            [seg((0, 0), (1, 0)), seg((1, 0), (1, 1))],
            tolerances: tolerances
        )
        #expect(chained.count == 2, "no chaining across corners in v1")
    }

    @Test func endpointToleranceGovernsJoins() {
        let s = tolerances.sampleSpacing
        let within = chainCollinearPaths(
            [seg((0, 0), (1, 0)), seg((1 + s / 32, 0), (2, 0))],
            tolerances: tolerances
        )
        #expect(within.count == 1)
        #expect(within[0].points.count == 2)

        let beyond = chainCollinearPaths(
            [seg((0, 0), (1, 0)), seg((1 + s / 4, 0), (2, 0))],
            tolerances: tolerances
        )
        #expect(beyond.count == 2)
    }

    @Test func kindsChainSeparately() {
        let chained = chainCollinearPaths(
            [seg((0, 0), (1, 0), .visible), seg((1, 0), (2, 0), .hidden)],
            tolerances: tolerances
        )
        #expect(chained.count == 2)
    }

    @Test func foldbacksDoNotChain() {
        // Second segment continues backward over the first: parallel and
        // touching, but direction reverses — must stay separate.
        let chained = chainCollinearPaths(
            [seg((0, 0), (1, 0)), seg((0.5, 0), (1, 0))],
            tolerances: tolerances
        )
        #expect(chained.count == 2)
    }

    @Test func chainingIsOrderInvariant() {
        let base = [
            seg((0, 0), (1, 1)), seg((1, 1), (2, 2)), seg((2, 2), (3, 3)),
            seg((0, 5), (1, 5), .hidden), seg((1, 5), (2, 5), .hidden),
            seg((7, 0), (7, 1)),
        ]
        let a = LineDrawing(canonicalizing: chainCollinearPaths(base, tolerances: tolerances))
        let b = LineDrawing(canonicalizing: chainCollinearPaths(
            base.reversed().map { LineDrawing.Path(points: $0.points.reversed(), kind: $0.kind) },
            tolerances: tolerances
        ))
        #expect(a == b)
        #expect(a.paths.count == 3)
    }

    @Test func collapsePreservesRealCorners() {
        let corner = [SIMD2<Double>(0, 0), SIMD2<Double>(1, 0), SIMD2<Double>(1, 1)]
        #expect(collapseCollinear(corner, tolerances: tolerances) == corner)

        let straight = [SIMD2<Double>(0, 0), SIMD2<Double>(1, 0),
                        SIMD2<Double>(2, 0), SIMD2<Double>(3, 0)]
        #expect(collapseCollinear(straight, tolerances: tolerances)
            == [SIMD2(0, 0), SIMD2(3, 0)])
    }

    // MARK: Suppression

    @Test func exactlyCoincidentHiddenIsDropped() {
        let paths = [seg((0, 0), (1, 0), .visible), seg((0, 0), (1, 0), .hidden)]
        let out = suppressHiddenCoincidentWithVisible(paths, tolerances: tolerances)
        #expect(out.count == 1)
        #expect(out[0].kind == .visible)
    }

    @Test func partialButSubstantialOverlapIsDropped() {
        let paths = [seg((0, 0), (1, 0), .visible), seg((0.5, 0), (1.5, 0), .hidden)]
        let out = suppressHiddenCoincidentWithVisible(paths, tolerances: tolerances)
        #expect(out.count == 1, "spec drops the whole hidden sub-segment")
    }

    @Test func bisectionScaleTouchSurvives() {
        // A hidden run that merely touches the visible run at a shared
        // transition point (overlap ≈ bisection noise) must NOT be dropped —
        // it is the real dashed continuation of a partially hidden edge.
        let touch = tolerances.bisectionTolerance
        let paths = [
            seg((1, 0), (2, 0), .visible),
            seg((0, 0), (1 + touch, 0), .hidden),
        ]
        let out = suppressHiddenCoincidentWithVisible(paths, tolerances: tolerances)
        #expect(out.count == 2)
    }

    @Test func lateralOffsetBeyondToleranceSurvives() {
        let offset = 2 * tolerances.coincidenceTolerance
        let paths = [
            seg((0, 0), (1, 0), .visible),
            seg((0, offset), (1, offset), .hidden),
        ]
        let out = suppressHiddenCoincidentWithVisible(paths, tolerances: tolerances)
        #expect(out.count == 2)

        let oneEndOff = [
            seg((0, 0), (1, 0), .visible),
            seg((0, 0), (1, 0.1), .hidden),
        ]
        #expect(suppressHiddenCoincidentWithVisible(oneEndOff, tolerances: tolerances).count == 2)
    }

    // MARK: End-to-end effects (default options: suppression ON)

    @Test func cubeFrontDefaultsHasNoHiddenPaths() {
        let drawing = makeLineDrawing(mesh: Fixtures.cube(), view: .front)
        #expect(drawing.paths.count == 4)
        #expect(drawing.paths.allSatisfy { $0.kind == .visible })
    }

    @Test func cylinderFrontDefaultsChainsCapsAndSuppressesBackRims() {
        let drawing = makeLineDrawing(mesh: Fixtures.cylinder(), view: .front)
        let visible = drawing.paths.filter { $0.kind == .visible }
        let hidden = drawing.paths.filter { $0.kind == .hidden }
        // 2 silhouettes + 1 chained top cap line + 1 chained bottom cap line.
        #expect(visible.count == 4)
        #expect(hidden.isEmpty, "back rims coincide with front rims → suppressed")
        let capLines = visible.filter { abs($0.points[0].y - $0.points[1].y) < 1e-9 }
        #expect(capLines.count == 2)
        for cap in capLines {
            #expect(abs(abs(cap.points[0].x) - 1) <= 1e-9)
            #expect(abs(abs(cap.points[1].x) - 1) <= 1e-9)
            #expect(cap.points.count == 2, "12 rim segments collapse into one straight span")
        }
    }

    @Test func isoCubeDefaultsKeepNonCoincidentHidden() {
        let drawing = makeLineDrawing(mesh: Fixtures.cube(), view: .isometric)
        #expect(drawing.paths.filter { $0.kind == .visible }.count == 9)
        #expect(drawing.paths.filter { $0.kind == .hidden }.count == 3,
                "iso hidden edges don't coincide with visible ones and must survive")
    }
}
