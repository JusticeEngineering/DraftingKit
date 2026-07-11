import Foundation
import Testing
@testable import WireframeCore

@Suite("Canonical ordering & bounds (pipeline stage 4.7)")
struct CanonicalOrderingTests {

    private func path(_ points: [(Double, Double)], _ kind: LineDrawing.Kind = .visible) -> LineDrawing.Path {
        LineDrawing.Path(points: points.map { SIMD2($0.0, $0.1) }, kind: kind)
    }

    @Test func pathDirectionIsNormalized() {
        let forward = LineDrawing(canonicalizing: [path([(0, 0), (1, 1)])])
        let backward = LineDrawing(canonicalizing: [path([(1, 1), (0, 0)])])
        #expect(forward == backward)
        #expect(forward.paths[0].points.first == SIMD2(0, 0))
    }

    @Test func sortIsByKindThenStartThenEnd() {
        let jumbled = [
            path([(5, 0), (6, 0)], .hidden),
            path([(1, 2), (1, 3)]),
            path([(0, 9), (0, 10)]),
            path([(1, 1), (1, 2)]),
            path([(0, 0), (0, 1)], .hidden),
            path([(1, 1), (2, 5)]),
        ]
        let drawing = LineDrawing(canonicalizing: jumbled)
        let kinds = drawing.paths.map(\.kind)
        #expect(kinds == [.visible, .visible, .visible, .visible, .hidden, .hidden])
        let visibleStarts = drawing.paths.prefix(4).map { $0.points[0] }
        #expect(visibleStarts == [SIMD2(0, 9), SIMD2(1, 1), SIMD2(1, 1), SIMD2(1, 2)])
        // Same start (1,1): ordered by end.
        #expect(drawing.paths[1].points.last! == SIMD2(1, 2))
        #expect(drawing.paths[2].points.last! == SIMD2(2, 5))
    }

    @Test func canonicalizingIsIdempotentAndOrderIndependent() {
        let paths = [
            path([(3, 1), (0, 0)]),
            path([(2, 2), (2, 0)], .hidden),
            path([(0, 0), (0, 5), (1, 5)]),
            path([(-1, 4), (2, 2)]),
        ]
        let a = LineDrawing(canonicalizing: paths)
        let b = LineDrawing(canonicalizing: paths.reversed().map {
            LineDrawing.Path(points: $0.points.reversed(), kind: $0.kind)
        })
        let c = LineDrawing(canonicalizing: a.paths)
        #expect(a == b)
        #expect(a == c)
    }

    // Invariant 7: bounds exactly equal the min/max over all emitted points.
    @Test func boundsAreTight() {
        let drawing = LineDrawing(canonicalizing: [
            path([(-2, 1), (3, 4)]),
            path([(0, -7), (0.5, 0.5), (1, 12)], .hidden),
        ])
        var mn = SIMD2<Double>(.infinity, .infinity)
        var mx = SIMD2<Double>(-.infinity, -.infinity)
        for p in drawing.paths.flatMap(\.points) {
            mn = pointwiseMin(mn, p)
            mx = pointwiseMax(mx, p)
        }
        #expect(drawing.bounds.min == mn)
        #expect(drawing.bounds.max == mx)
        #expect(drawing.bounds == Rect2D(min: SIMD2(-2, -7), max: SIMD2(3, 12)))
    }

    @Test func emptyDrawingHasZeroBounds() {
        let drawing = LineDrawing(canonicalizing: [])
        #expect(drawing.paths.isEmpty)
        #expect(drawing.bounds == .zero)
    }

    @Test func codableRoundTripsExactly() throws {
        let drawing = LineDrawing(canonicalizing: [
            path([(0.1, 0.2), (1.0 / 3.0, 2.0 / 7.0)]),
            path([(-1e-9, 4e17), (0, 1)], .hidden),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(drawing)
        let decoded = try JSONDecoder().decode(LineDrawing.self, from: data)
        #expect(decoded == drawing)  // bit-exact round trip
    }
}

@Suite("Pipeline modes & graceful degradation")
struct XRayPipelineTests {

    @Test func cubeFrontXRay() {
        let drawing = runPipeline(mesh: Fixtures.cube(), view: .front,
                                  options: .init(), mode: .xray)
        // 12 crease candidates − 4 depth-parallel edges = 8 segments: the
        // front square and the back square projected onto it, all visible
        // because x-ray mode skips occlusion.
        #expect(drawing.paths.count == 8)
        #expect(drawing.paths.allSatisfy { $0.kind == .visible })
        #expect(drawing.paths.allSatisfy { $0.points.count == 2 })
        for path in drawing.paths {
            let d = path.points[1] - path.points[0]
            #expect(abs(length(d) - 1) < 1e-12, "cube edges project to unit length")
        }
        #expect(drawing.bounds == Rect2D(min: SIMD2(0, 0), max: SIMD2(1, 1)))
    }

    @Test func cubeIsometricXRay() {
        let drawing = runPipeline(mesh: Fixtures.cube(), view: .isometric,
                                  options: .init(), mode: .xray)
        // All 12 edges survive in iso — none is view-parallel.
        #expect(drawing.paths.count == 12)
        #expect(drawing.paths.allSatisfy { $0.kind == .visible })
    }

    @Test func identicalRunsProduceIdenticalJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let a = try encoder.encode(makeLineDrawing(mesh: Fixtures.lBracket(), view: .isometric))
        let b = try encoder.encode(makeLineDrawing(mesh: Fixtures.lBracket(), view: .isometric))
        #expect(a == b)
    }

    @Test func emptyMeshYieldsEmptyDrawing() {
        var diag = MeshDiagnostics()
        let empty = Mesh(weldingSoup: [], tolerance: 1e-6, diagnostics: &diag)
        let drawing = makeLineDrawing(mesh: empty, view: .front)
        #expect(drawing.paths.isEmpty)
        #expect(drawing.bounds == .zero)
    }

    @Test func flatProjectionsDegradeGracefully() {
        // A triangle lying in the XY plane seen from the front projects onto
        // the x axis (screen y = world z = 0 everywhere): still emitted,
        // collapsed, no crash.
        var diag = MeshDiagnostics()
        let flat = Mesh(
            weldingSoup: [(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0.5, 5, 0))],
            tolerance: 1e-6,
            diagnostics: &diag
        )
        let drawing = makeLineDrawing(mesh: flat, view: .front)
        // The 3 boundary edges all project onto y = 0; the two apex edges
        // chain into one span, the base edge stays separate (a foldback).
        #expect(drawing.paths.count == 2)
        #expect(drawing.paths.allSatisfy { path in path.points.allSatisfy { $0.y == 0 } })
    }

    @Test func projectionCollapsedToSliverDropsViewParallelEdges() {
        // Front view of a triangle spanning depth: screen footprint is a
        // 0.001-tall sliver at x = 0. The edge parallel to the view axis
        // projects below the minimum length and is dropped; the two sliver
        // edges survive.
        var diag = MeshDiagnostics()
        let sliver = Mesh(
            weldingSoup: [(SIMD3(0, 0, 0), SIMD3(0, 2, 0), SIMD3(0, 1, 0.001))],
            tolerance: 1e-9,
            diagnostics: &diag
        )
        let front = makeLineDrawing(mesh: sliver, view: .front)
        #expect(front.paths.count == 2)
        #expect(front.bounds.size.x == 0)
        #expect(abs(front.bounds.size.y - 0.001) < 1e-15)
    }
}

@Suite("SVG output")
struct SVGTests {

    @Test func svgStructureAndViewBox() {
        let drawing = makeLineDrawing(mesh: Fixtures.cube(), view: .front)
        let svg = drawing.svg(margin: 2)
        #expect(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        #expect(svg.hasSuffix("</svg>\n"))
        // Bounds 1×1 + margins → viewBox 0 0 5 5.
        #expect(svg.contains("viewBox=\"0 0 5.0 5.0\""))
        // Defaults suppress the coincident back edges: 4 visible paths only.
        #expect(svg.components(separatedBy: "<polyline").count - 1 == 4)
        #expect(!svg.contains("stroke-dasharray"), "coincident hidden edges are suppressed")
    }

    @Test func svgIsYFlipped() {
        let drawing = LineDrawing(canonicalizing: [
            LineDrawing.Path(points: [SIMD2(0, 0), SIMD2(0, 10)], kind: .visible)
        ])
        let svg = drawing.svg(margin: 0)
        // Model-space top (y=10) must map to SVG top (y=0).
        #expect(svg.contains("points=\"0.0,10.0 0.0,0.0\""))
    }

    @Test func hiddenPathsAreDashed() {
        let drawing = LineDrawing(canonicalizing: [
            LineDrawing.Path(points: [SIMD2(0, 0), SIMD2(1, 0)], kind: .visible),
            LineDrawing.Path(points: [SIMD2(0, 1), SIMD2(1, 1)], kind: .hidden),
        ])
        let svg = drawing.svg(hiddenDashPattern: [5, 2.5])
        #expect(svg.contains("class=\"visible\""))
        #expect(svg.contains("class=\"hidden\""))
        #expect(svg.contains("stroke-dasharray=\"5.0 2.5\""))
    }

    @Test func hiddenLinesAreThinnerAndGrayByDefault() {
        let drawing = LineDrawing(canonicalizing: [
            LineDrawing.Path(points: [SIMD2(0, 0), SIMD2(1, 0)], kind: .visible),
            LineDrawing.Path(points: [SIMD2(0, 1), SIMD2(1, 1)], kind: .hidden),
        ])
        let svg = drawing.svg(strokeWidth: 2.0)
        #expect(svg.contains("stroke=\"black\" stroke-width=\"2.0\""))
        #expect(svg.contains("stroke=\"#808080\" stroke-width=\"1.25\""),
                "hidden defaults to 62.5% width, gray")

        let custom = drawing.svg(strokeWidth: 2.0, hiddenStrokeWidth: 0.4,
                                 visibleColor: "#000080", hiddenColor: "red")
        #expect(custom.contains("stroke=\"#000080\" stroke-width=\"2.0\""))
        #expect(custom.contains("stroke=\"red\" stroke-width=\"0.4\""))
    }

    @Test func emptyDrawingStillValidSVG() {
        let svg = LineDrawing(canonicalizing: []).svg()
        #expect(svg.contains("viewBox=\"0 0 4.0 4.0\""))
        #expect(!svg.contains("<polyline"))
    }
}
