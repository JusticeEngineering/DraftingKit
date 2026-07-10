import Foundation
import Testing
@testable import WireframeCore

@Suite("Edge classification (pipeline stage 4.2)")
struct ClassificationTests {

    private func classify(_ mesh: Mesh,
                          view: OrthographicView,
                          creaseAngleDegrees: Double = 30) -> [(edgeIndex: Int, reason: EdgeReason)] {
        var options = DrawingOptions()
        options.creaseAngleDegrees = creaseAngleDegrees
        let tolerances = Tolerances(options: options,
                                    modelDiagonal: mesh.boundingDiagonal,
                                    projectedDiagonal: 1)
        return classifyCandidateEdges(mesh: mesh, view: view, tolerances: tolerances)
    }

    @Test func cubeGeometricEdgesAreCreasesFaceDiagonalsAreNot() {
        let cube = Fixtures.cube()
        let candidates = classify(cube, view: .front)
        // All 12 geometric edges are 90° creases; the 6 face diagonals join
        // coplanar triangles (dihedral 0°) and must not be candidates.
        #expect(candidates.count == 12)
        #expect(candidates.allSatisfy { $0.reason == .crease })
        for c in candidates {
            let edge = cube.edges[c.edgeIndex]
            let d = cube.positions[edge.a] - cube.positions[edge.b]
            #expect(abs(length(d) - 1) < 1e-12, "candidates must be unit edges, not diagonals")
        }
    }

    @Test func grazingFacesAreNotSilhouettes() {
        // With the crease threshold above 90°, cube side faces (dot ≈ 0,
        // its own sign class) must not pair with front/back faces (dot ±1)
        // as silhouettes: (0, ±) is not a strict sign flip.
        let candidates = classify(Fixtures.cube(), view: .front, creaseAngleDegrees: 91)
        #expect(candidates.isEmpty)
    }

    @Test func cylinderFrontViewHasExactlyTwoSilhouettes() {
        let cylinder = Fixtures.cylinder()
        let candidates = classify(cylinder, view: .front)
        let silhouettes = candidates.filter { $0.reason == .silhouette }
        let creases = candidates.filter { $0.reason == .crease }
        #expect(silhouettes.count == 2)
        // Cap rims: 24 top + 24 bottom edges at ~90° to the side wall.
        #expect(creases.count == 48)
        // Silhouette edges must be the vertical side edges at screenX ≈ ±r.
        for s in silhouettes {
            let edge = cylinder.edges[s.edgeIndex]
            let a = cylinder.positions[edge.a]
            let b = cylinder.positions[edge.b]
            #expect(abs(a.x - b.x) < 1e-12 && abs(a.y - b.y) < 1e-12, "silhouettes are vertical")
        }
    }

    @Test func silhouettesFollowTheView() {
        // The same cylinder seen from the top has no silhouette side edges:
        // all side faces are edge-on (grazing), caps face the viewer.
        let candidates = classify(Fixtures.cylinder(), view: .top)
        #expect(candidates.allSatisfy { $0.reason != .silhouette })
    }

    @Test func boundaryAndNonManifoldEdgesAreAlwaysCandidates() {
        var diag = MeshDiagnostics()
        let single = Mesh(
            weldingSoup: [(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0))],
            tolerance: 1e-6,
            diagnostics: &diag
        )
        let singleCandidates = classify(single, view: .top)
        #expect(singleCandidates.count == 3)
        #expect(singleCandidates.allSatisfy { $0.reason == .boundary })

        let fan = Mesh(
            weldingSoup: [
                (SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
                (SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
                (SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(-1, 0, 0)),
            ],
            tolerance: 1e-6,
            diagnostics: &diag
        )
        let fanCandidates = classify(fan, view: .front)
        // 6 boundary rim edges + the shared non-manifold edge: all drawn.
        #expect(fanCandidates.count == 7)
        #expect(fanCandidates.allSatisfy { $0.reason == .boundary })
    }

    @Test func lBracketIsoCreases() {
        let bracket = Fixtures.lBracket()
        let candidates = classify(bracket, view: .isometric)
        // Rim creases: 7 outline segments × 2 caps = 14 (cap ⊥ wall).
        // Lateral creases: 6 of the 7 outline vertices are real corners — the
        // split vertex (0, 0.5) joins two collinear segments, so its lateral
        // edge lies between coplanar walls (0°) and must not be a candidate.
        // Cap-interior and wall diagonals are coplanar. No silhouettes: every
        // sign-flipping face pair here already meets at a crease.
        let creases = candidates.filter { $0.reason == .crease }
        #expect(creases.count == 20)
        #expect(candidates.count == 20)
        // The collinear-split edges must NOT be candidates: no candidate edge
        // connects (0,0,0.5)–(0,1,0.5) or lies between the two coplanar
        // x = 0 wall quads / cap pieces at the split vertex.
        let split = SIMD3<Double>(0, 0, 0.5)
        for c in candidates where c.reason == .crease {
            let edge = bracket.edges[c.edgeIndex]
            let a = bracket.positions[edge.a]
            let b = bracket.positions[edge.b]
            let isSplitLateral = (length(a - split) < 1e-12 && abs(b.y - 1) < 1e-12 && length(SIMD3(b.x, 0, b.z) - split) < 1e-12)
                || (length(b - split) < 1e-12 && abs(a.y - 1) < 1e-12 && length(SIMD3(a.x, 0, a.z) - split) < 1e-12)
            #expect(!isSplitLateral, "collinear split edge must not be a crease")
        }
    }

    @Test func projectedLengthFilterDropsViewAxisEdges() {
        // Cube front view: the 4 depth edges (along +Y) project to points.
        let cube = Fixtures.cube()
        let options = DrawingOptions()
        let projected = projectPositions(cube.positions, view: .front)
        let tolerances = Tolerances(options: options,
                                    modelDiagonal: cube.boundingDiagonal,
                                    projectedDiagonal: projectedBoundsDiagonal(projected))
        let candidates = classifyCandidateEdges(mesh: cube, view: .front, tolerances: tolerances)
        let segments = projectCandidates(candidates, mesh: cube,
                                         projected: projected, tolerances: tolerances)
        #expect(candidates.count == 12)
        #expect(segments.count == 8)
        for segment in segments {
            let d = segment.end - segment.start
            #expect(abs((d.x * d.x + d.y * d.y).squareRoot() - 1) < 1e-12)
        }
    }
}
