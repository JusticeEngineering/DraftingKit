import Foundation
import Testing
@testable import WireframeCore

// Acceptance invariants 1–4 (SPEC §7). Suppression (stage 4.6) lands in M4,
// so every test here disables it explicitly — these exact tests must keep
// passing unchanged once suppression exists; M4 adds the suppression-on
// variants.

@Suite("Acceptance invariants (SPEC §7)")
struct InvariantTests {

    private var noSuppression: DrawingOptions {
        var options = DrawingOptions()
        options.suppressHiddenCoincidentWithVisible = false
        return options
    }

    // Invariant 1 — cube, front view.
    @Test func cubeFrontView() {
        let drawing = makeLineDrawing(mesh: Fixtures.cube(), view: .front, options: noSuppression)
        let visible = drawing.paths.filter { $0.kind == .visible }
        let hidden = drawing.paths.filter { $0.kind == .hidden }

        // Exactly 4 visible paths, each a straight unit segment, forming the
        // unit square; the 4 back edges project onto exactly the same square
        // and (suppression off) emit as 4 coinciding hidden paths.
        #expect(visible.count == 4)
        #expect(hidden.count == 4)
        for path in drawing.paths {
            #expect(path.points.count == 2)
            #expect(abs(length(path.points[1] - path.points[0]) - 1) <= 1e-9)
        }
        #expect(visible.map(\.points) == hidden.map(\.points),
                "back edges coincide with front edges exactly")
        let corners = Set(visible.flatMap(\.points))
        #expect(corners == [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)])
        #expect(drawing.bounds == Rect2D(min: SIMD2(0, 0), max: SIMD2(1, 1)))

        // includeHiddenLines = false drops the hidden square.
        var options = noSuppression
        options.includeHiddenLines = false
        let visibleOnly = makeLineDrawing(mesh: Fixtures.cube(), view: .front, options: options)
        #expect(visibleOnly.paths.count == 4)
        #expect(visibleOnly.paths.allSatisfy { $0.kind == .visible })

        // With suppression (the default): the hidden square coincides with
        // the visible one and disappears — 4 visible, 0 hidden.
        let suppressed = makeLineDrawing(mesh: Fixtures.cube(), view: .front)
        #expect(suppressed.paths.count == 4)
        #expect(suppressed.paths.allSatisfy { $0.kind == .visible })
    }

    // Invariant 2 — cube, isometric: the classic 9 visible + 3 hidden.
    @Test func cubeIsometric() {
        let drawing = makeLineDrawing(mesh: Fixtures.cube(), view: .isometric, options: noSuppression)
        let visible = drawing.paths.filter { $0.kind == .visible }
        let hidden = drawing.paths.filter { $0.kind == .hidden }
        #expect(visible.count == 9)
        #expect(hidden.count == 3)

        // The hidden edges all connect to the far corner (0, 1, 0), which
        // projects to the hexagon center (coincident with the near corner).
        let farCorner = OrthographicView.isometric.project(SIMD3(0, 1, 0))
        let center = SIMD2(farCorner.x, farCorner.y)
        for path in hidden {
            let touchesCenter = path.points.contains { length($0 - center) <= 1e-9 }
            #expect(touchesCenter, "hidden path must connect to the far corner")
        }
    }

    // Invariant 3 — cylinder (24 segments), front view.
    @Test func cylinderFrontView() {
        let radius = 1.0, height = 2.0
        let mesh = Fixtures.cylinder(radius: radius, height: height)
        let drawing = makeLineDrawing(mesh: mesh, view: .front, options: noSuppression)
        let visible = drawing.paths.filter { $0.kind == .visible }

        // Exactly 2 straight visible silhouette lines at screenX = ±radius.
        // (Verticality is part of the filter: chained cap lines also END at
        // x = ±radius but run horizontally.)
        let silhouettes = visible.filter { path in
            path.points.allSatisfy { abs(abs($0.x) - radius) <= 1e-6 }
                && abs(path.points[0].x - path.points[path.points.count - 1].x) <= 1e-6
        }
        #expect(silhouettes.count == 2)
        for path in silhouettes {
            #expect(abs(path.points[0].x - path.points[1].x) <= 1e-6,
                    "silhouette must not deviate from vertical")
            #expect(abs(length(path.points[1] - path.points[0]) - height) <= 1e-6)
        }
        #expect(Set(silhouettes.flatMap(\.points).map(\.x)).count == 2, "one at +r, one at -r")

        // Everything else visible must be top/bottom cap lines (y = 0 or h).
        for path in visible where !silhouettes.contains(path) {
            let y = path.points[0].y
            #expect(abs(y) <= 1e-9 || abs(y - height) <= 1e-9)
            #expect(path.points.allSatisfy { abs($0.y - y) <= 1e-9 }, "cap lines are horizontal")
        }
        // Cap lines span the full width.
        let capXs = visible.filter { abs($0.points[0].y - height) <= 1e-9 }.flatMap(\.points).map(\.x)
        #expect(abs(capXs.min()! + radius) <= 1e-9)
        #expect(abs(capXs.max()! - radius) <= 1e-9)
    }

    // Invariant 4 — two offset boxes, front view. M3 form: the far box has
    // hidden geometry inside the near box's projected rectangle. (The exact
    // spec form — EVERY hidden path inside that rectangle — additionally
    // requires suppression to remove hidden lines coincident with visible
    // ones, so it lands with M4.)
    @Test func twoOffsetBoxesFrontView() {
        let mesh = Fixtures.twoOffsetBoxes()
        let drawing = makeLineDrawing(mesh: mesh, view: .front, options: noSuppression)
        let hidden = drawing.paths.filter { $0.kind == .hidden }
        #expect(!hidden.isEmpty, "far box must have hidden paths")

        // Near box projects to [0,1]², grown by epsilon.
        let epsilon = 1e-6 * mesh.boundingDiagonal
        let nearRect = Rect2D(min: SIMD2(-epsilon, -epsilon), max: SIMD2(1 + epsilon, 1 + epsilon))
        func inside(_ p: SIMD2<Double>) -> Bool {
            p.x >= nearRect.min.x && p.x <= nearRect.max.x
                && p.y >= nearRect.min.y && p.y <= nearRect.max.y
        }
        // Hidden-by-the-near-box geometry exists and lies inside its rect.
        let insideNear = hidden.filter { $0.points.allSatisfy(inside) }
        #expect(!insideNear.isEmpty, "occlusion by the near box must produce hidden paths inside it")

        // Far-box hidden paths caused by the near box come from far-box
        // edges at x or y = 0.5..1 crossing the overlap — check one known
        // one: the far box's bottom-front edge (z = 0.5) must be split, its
        // hidden part ending near x = 1 (the near box's right edge).
        let bottomFarHidden = hidden.filter { path in
            path.points.allSatisfy { abs($0.y - 0.5) <= 1e-9 }
        }
        #expect(bottomFarHidden.contains { path in
            path.points.contains { abs($0.x - 1) <= 1e-3 }
        }, "far bottom edge's hidden run should end at the near box boundary")
    }

    // Invariant 4, exact spec form (suppression ON, the default): every
    // remaining hidden path lies inside the near box's projected rectangle —
    // coincident duplicates (near-box back edges, far-box back edges over
    // their visible front edges) are suppressed, leaving only the dashes
    // caused by real near-box occlusion.
    @Test func twoOffsetBoxesSuppressedHiddenLiesInsideNearRect() {
        let mesh = Fixtures.twoOffsetBoxes()
        let drawing = makeLineDrawing(mesh: mesh, view: .front)
        let hidden = drawing.paths.filter { $0.kind == .hidden }
        #expect(!hidden.isEmpty, "far box must still have hidden paths")

        // Grow the near rectangle by 2 × bisection tolerance — transitions
        // are localized within that.
        let scene = prepareScene(mesh: mesh, view: .front, options: .init())!
        let grow = 2 * scene.tolerances.bisectionTolerance
        for path in hidden {
            for p in path.points {
                #expect(p.x >= -grow && p.x <= 1 + grow && p.y >= -grow && p.y <= 1 + grow,
                        "hidden point \(p) must lie inside the near box's rectangle")
            }
        }
    }
}
