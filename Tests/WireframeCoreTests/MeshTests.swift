import Foundation
import Testing
@testable import WireframeCore

@Suite("Welding & adjacency (pipeline stage 4.1)")
struct MeshTests {

    // Invariant 8: cube-as-STL-soup (36 vertices) welds to 8 positions,
    // 18 edges, 0 boundary, 0 non-manifold.
    @Test func weldCubeSoup() {
        var diag = MeshDiagnostics()
        let mesh = Mesh(weldingSoup: Fixtures.cubeSoup(), tolerance: 1e-6, diagnostics: &diag)

        #expect(diag.inputTriangleCount == 12)
        #expect(diag.weldedVertexCount == 8)
        #expect(diag.degenerateTrianglesDropped == 0)
        #expect(diag.boundaryEdgeCount == 0)
        #expect(diag.nonManifoldEdgeCount == 0)

        #expect(mesh.positions.count == 8)
        #expect(mesh.triangles.count == 12)
        #expect(mesh.edges.count == 18)
        #expect(mesh.edges.allSatisfy { $0.faces.count == 2 })
        #expect(Set(mesh.positions) == Set(Fixtures.cube().positions))
    }

    @Test func weldMergesWithinToleranceAcrossCellBoundaries() {
        // Jitter duplicated cube vertices across quantization cell boundaries,
        // keeping every pair of copies within tolerance (max separation
        // 2 × 2e-7 × √3 ≈ 6.9e-7 < 1e-6) so merging can't depend on order.
        let jittered = Fixtures.cubeSoup().enumerated().map { index, tri in
            let wobble = 0.2e-6 * Double((index % 3) - 1)  // -2e-7, 0, +2e-7
            let d = SIMD3(wobble, -wobble, wobble)
            return (tri.0 + d, tri.1 + d, tri.2 + d)
        }
        var diag = MeshDiagnostics()
        let mesh = Mesh(weldingSoup: jittered, tolerance: 1e-6, diagnostics: &diag)
        #expect(mesh.positions.count == 8)
        #expect(mesh.edges.count == 18)
        #expect(diag.degenerateTrianglesDropped == 0)
    }

    @Test func weldDoesNotMergeBeyondTolerance() {
        let a = SIMD3<Double>(0, 0, 0)
        let b = SIMD3<Double>(1, 0, 0)
        let c = SIMD3<Double>(0, 1, 0)
        // Second triangle shares an edge only approximately — 10× tolerance off.
        let offset = SIMD3<Double>(0, 0, 1e-5)
        var diag = MeshDiagnostics()
        let mesh = Mesh(
            weldingSoup: [(a, b, c), (a + offset, SIMD3(0, -1, 0), b + offset)],
            tolerance: 1e-6,
            diagnostics: &diag
        )
        #expect(mesh.positions.count == 6)
        #expect(diag.boundaryEdgeCount == 6)
    }

    @Test func degenerateTrianglesDropAndCount() {
        let p = SIMD3<Double>(9, 9, 9)
        let q = SIMD3<Double>(9, 9, 10)
        var soup = Fixtures.cubeSoup()
        soup.append((p, p, q))                                          // repeated vertex
        soup.append((SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)))   // exactly collinear
        soup.append((SIMD3(0, 0, 0), SIMD3(1e-9, 0, 0), SIMD3(5, 5, 5))) // welds to repeated
        soup.append((SIMD3(0, 0, 0), SIMD3(.nan, 0, 0), SIMD3(0, 5, 5))) // non-finite

        var diag = MeshDiagnostics()
        let mesh = Mesh(weldingSoup: soup, tolerance: 1e-6, diagnostics: &diag)

        #expect(diag.inputTriangleCount == 16)
        #expect(diag.degenerateTrianglesDropped == 4)
        #expect(mesh.triangles.count == 12)
        // Orphan vertices from dropped triangles must not survive (they would
        // inflate boundingBox, which downstream tolerances derive from).
        #expect(diag.weldedVertexCount == 8)
        #expect(mesh.positions.count == 8)
        #expect(mesh.boundingBox.max == SIMD3(1, 1, 1))
    }

    @Test func emptySoupYieldsEmptyMeshWithoutThrowing() {
        var diag = MeshDiagnostics()
        let mesh = Mesh(weldingSoup: [], tolerance: 1e-6, diagnostics: &diag)
        #expect(mesh.positions.isEmpty)
        #expect(mesh.triangles.isEmpty)
        #expect(mesh.boundingBox.min == .zero)
        #expect(mesh.boundingDiagonal == 0)
        #expect(diag == MeshDiagnostics())
    }

    // MARK: Validating init

    @Test func validatingInitRejectsOutOfRangeIndices() {
        let positions = [SIMD3<Double>(0, 0, 0), SIMD3<Double>(1, 0, 0), SIMD3<Double>(0, 1, 0)]
        #expect(throws: MeshError.invalidIndex) {
            try Mesh(positions: positions, triangles: [SIMD3(0, 1, 3)])
        }
        #expect(throws: MeshError.invalidIndex) {
            try Mesh(positions: positions, triangles: [SIMD3(0, 1, -1)])
        }
    }

    @Test func validatingInitRejectsEmptyMesh() {
        #expect(throws: MeshError.emptyMesh) {
            try Mesh(positions: [], triangles: [])
        }
        #expect(throws: MeshError.emptyMesh) {
            try Mesh(positions: [SIMD3<Double>(0, 0, 0)], triangles: [])
        }
    }

    // MARK: Adjacency & normals

    @Test func singleTriangleHasThreeBoundaryEdges() {
        var diag = MeshDiagnostics()
        let mesh = Mesh(
            weldingSoup: [(SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0))],
            tolerance: 1e-6,
            diagnostics: &diag
        )
        #expect(diag.boundaryEdgeCount == 3)
        #expect(diag.nonManifoldEdgeCount == 0)
        #expect(mesh.edges.count == 3)
        #expect(mesh.faceNormals == [SIMD3(0, 0, 1)])
    }

    @Test func fanOfThreeTrianglesIsNonManifold() {
        let p0 = SIMD3<Double>(0, 0, 0)
        let p1 = SIMD3<Double>(0, 0, 1)
        var diag = MeshDiagnostics()
        let mesh = Mesh(
            weldingSoup: [
                (p0, p1, SIMD3(1, 0, 0)),
                (p0, p1, SIMD3(0, 1, 0)),
                (p0, p1, SIMD3(-1, 0, 0)),
            ],
            tolerance: 1e-6,
            diagnostics: &diag
        )
        #expect(diag.nonManifoldEdgeCount == 1)
        #expect(diag.boundaryEdgeCount == 6)
        #expect(mesh.edges.count == 7)
        let shared = mesh.edges.first { $0.faces.count == 3 }
        #expect(shared?.faces == [0, 1, 2])
    }

    @Test func cubeFaceNormalsAreUnitAxisAligned() {
        let mesh = Fixtures.cube()
        for normal in mesh.faceNormals {
            #expect(abs(length(normal) - 1) < 1e-12)
            let sorted = [abs(normal.x), abs(normal.y), abs(normal.z)].sorted()
            #expect(sorted[0] == 0 && sorted[1] == 0 && sorted[2] == 1)
        }
    }

    @Test func edgesAreCanonicallyOrdered() {
        let mesh = Fixtures.cylinder()
        for edge in mesh.edges {
            #expect(edge.a < edge.b)
            #expect(edge.faces == edge.faces.sorted())
        }
        let keys = mesh.edges.map { [$0.a, $0.b] }
        #expect(keys == keys.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) })
    }

    // MARK: Bounding box

    @Test func boundingBoxAndDiagonal() {
        let cube = Fixtures.cube()
        #expect(cube.boundingBox.min == .zero)
        #expect(cube.boundingBox.max == SIMD3(1, 1, 1))
        #expect(abs(cube.boundingDiagonal - 3.0.squareRoot()) < 1e-12)

        let boxes = Fixtures.twoOffsetBoxes()
        #expect(boxes.boundingBox.min == .zero)
        #expect(boxes.boundingBox.max == SIMD3(1.5, 4, 1.5))
    }

    // MARK: Fixture sanity — all fixtures closed, manifold, outward-wound

    @Test(arguments: [
        ("cube", 12, 18, 1.0),
        ("cylinder", 96, 144, 24.0 / 2 * Foundation.sin(2 * Double.pi / 24) * 2),
        ("twoOffsetBoxes", 24, 36, 2.0),
        ("lBracket", 24, 36, 1.75),
    ])
    func fixtureTopologyAndVolume(_ fixture: (String, Int, Int, Double)) {
        let (name, triangleCount, edgeCount, volume) = fixture
        let mesh: Mesh
        switch name {
        case "cube": mesh = Fixtures.cube()
        case "cylinder": mesh = Fixtures.cylinder()
        case "twoOffsetBoxes": mesh = Fixtures.twoOffsetBoxes()
        default: mesh = Fixtures.lBracket()
        }
        #expect(mesh.triangles.count == triangleCount, "\(name)")
        #expect(mesh.edges.count == edgeCount, "\(name)")
        #expect(mesh.edges.allSatisfy { $0.faces.count == 2 }, "\(name) must be closed + manifold")
        #expect(abs(Fixtures.signedVolume(of: mesh) - volume) < 1e-9, "\(name) winding/volume")
        for normal in mesh.faceNormals {
            #expect(abs(length(normal) - 1) < 1e-12, "\(name) normals must be unit")
        }
    }
}
