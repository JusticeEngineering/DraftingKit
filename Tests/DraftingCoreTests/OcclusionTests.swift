import Foundation
import Testing
@testable import DraftingCore

@Suite("Occlusion test & BVH (pipeline stage 4.5)")
struct OcclusionTests {

    private func makeTester(_ mesh: Mesh, _ view: OrthographicView)
        -> (tester: OcclusionTester, tolerances: Tolerances, projected: [SIMD3<Double>])
    {
        let projected = projectPositions(mesh.positions, view: view)
        let tolerances = Tolerances(options: .init(),
                                    modelDiagonal: mesh.boundingDiagonal,
                                    projectedDiagonal: projectedBoundsDiagonal(projected))
        return (OcclusionTester(mesh: mesh, projected: projected, tolerances: tolerances),
                tolerances, projected)
    }

    @Test func samplesBehindInsideAndOutsideTheCube() {
        let (tester, _, _) = makeTester(Fixtures.cube(), .front)
        // Front view: depth = world y; the front face sits at depth 0.
        #expect(tester.isHidden(SIMD3(0.5, 0.5, 0.5), ownFaces: []))   // inside → behind front face
        #expect(tester.isHidden(SIMD3(0.5, 0.5, 9), ownFaces: []))     // far behind
        #expect(!tester.isHidden(SIMD3(0.5, 0.5, -1), ownFaces: []))   // in front of everything
        #expect(!tester.isHidden(SIMD3(2, 0.5, 9), ownFaces: []))      // outside the footprint
        #expect(!tester.isHidden(SIMD3(-0.01, 0.5, 9), ownFaces: []))  // just outside
    }

    @Test func depthEpsilonProtectsCoplanarSamples() {
        let (tester, tolerances, _) = makeTester(Fixtures.cube(), .front)
        let epsilon = tolerances.depthEpsilon
        // Exactly on the front face plane: not occluded by it.
        #expect(!tester.isHidden(SIMD3(0.5, 0.5, 0), ownFaces: []))
        // Within epsilon behind it: still not occluded.
        #expect(!tester.isHidden(SIMD3(0.5, 0.5, epsilon / 2), ownFaces: []))
        // Beyond epsilon: occluded.
        #expect(tester.isHidden(SIMD3(0.5, 0.5, 2 * epsilon), ownFaces: []))
    }

    @Test func ownFacesDoNotOcclude() {
        var diag = MeshDiagnostics()
        let single = Mesh(
            weldingSoup: [(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))],
            tolerance: 1e-6,
            diagnostics: &diag
        )
        let (tester, _, _) = makeTester(single, .front)
        let sample = SIMD3(0.25, 0.25, 1.0)  // inside the projection, behind the face
        #expect(tester.isHidden(sample, ownFaces: []))
        #expect(!tester.isHidden(sample, ownFaces: [0]))
    }

    @Test func inclusiveContainmentOnProjectedBoundary() {
        let (tester, _, _) = makeTester(Fixtures.cube(), .front)
        // Samples exactly on the projected square's boundary, behind the
        // front face: contained inclusively → hidden. This is what makes a
        // cube's back edges classify as hidden rather than flickering.
        #expect(tester.isHidden(SIMD3(0.5, 1, 1), ownFaces: []))
        #expect(tester.isHidden(SIMD3(0, 0.5, 1), ownFaces: []))
        #expect(tester.isHidden(SIMD3(1, 1, 1), ownFaces: []))  // corner
    }

    @Test func nearEdgeOnOccludersAreExcluded() {
        var diag = MeshDiagnostics()
        // Nearly view-parallel triangle: real 3D area, but projected area
        // ~5e-13 — far below s². Must not occlude anything.
        let sliver = Mesh(
            weldingSoup: [(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0.5, 1, 1e-12))],
            tolerance: 1e-9,
            diagnostics: &diag
        )
        let (tester, _, _) = makeTester(sliver, .front)
        #expect(tester.occluderCount == 0)
        #expect(!tester.isHidden(SIMD3(0.5, 0, 5), ownFaces: []))
    }

    @Test func bvhMatchesBruteForce() {
        let cases: [(Mesh, OrthographicView)] = [
            (Fixtures.twoOffsetBoxes(), .isometric),
            (Fixtures.cylinder(), .front),
            (Fixtures.lBracket(), .top),
        ]
        for (mesh, view) in cases {
            let (tester, _, projected) = makeTester(mesh, view)
            var mn = projected[0], mx = projected[0]
            for p in projected {
                mn = pointwiseMin(mn, p)
                mx = pointwiseMax(mx, p)
            }
            // Deterministic grid sweep across the projection, 3 depth slices,
            // deliberately extending slightly outside the bounds.
            var mismatches = 0
            for ix in 0...30 {
                for iy in 0...30 {
                    let x = mn.x - 0.05 + (mx.x - mn.x + 0.1) * Double(ix) / 30
                    let y = mn.y - 0.05 + (mx.y - mn.y + 0.1) * Double(iy) / 30
                    for fz in [0.25, 0.5, 1.0] {
                        let z = mn.z + (mx.z - mn.z) * fz + 0.01
                        let sample = SIMD3(x, y, z)
                        if tester.isHidden(sample, ownFaces: [])
                            != tester.bruteForceIsHidden(sample, ownFaces: []) {
                            mismatches += 1
                        }
                    }
                }
            }
            #expect(mismatches == 0)
        }
    }

    @Test func bvhIsDeterministicAndComplete() {
        let boxes: [SIMD4<Double>] = (0..<137).map { i in
            let x = Double((i * 37) % 101) / 10
            let y = Double((i * 53) % 89) / 10
            let size = Double(i % 7) / 5 + 0.1
            return SIMD4(x, y, x + size, y + size)
        }
        let a = BVH(boxes: boxes)
        let b = BVH(boxes: boxes)
        #expect(a == b)
        #expect(a.order.sorted() == Array(0..<137))
        for node in a.nodes where node.left >= 0 {
            let left = a.nodes[Int(node.left)]
            let right = a.nodes[Int(node.right)]
            #expect(left.minX >= node.minX && left.maxX <= node.maxX)
            #expect(right.minX >= node.minX && right.maxX <= node.maxX)
            #expect(left.minY >= node.minY && left.maxY <= node.maxY)
            #expect(right.minY >= node.minY && right.maxY <= node.maxY)
        }
        #expect(BVH(boxes: []).nodes.isEmpty)
    }
}
