// Procedural test fixtures — code, not files, so they're readable and exact.
// All meshes are closed, outward-wound (CCW from outside), Z-up unless noted.

import Foundation
@testable import DraftingCore

enum Fixtures {
    /// Triangle indices for an axis-aligned box using the corner ordering
    /// 0…3 = bottom ring (z = min), 4…7 = top ring (z = max), CCW from above
    /// starting at (min.x, min.y).
    static let boxTriangles: [SIMD3<Int>] = [
        SIMD3(0, 2, 1), SIMD3(0, 3, 2),     // bottom (-Z)
        SIMD3(4, 5, 6), SIMD3(4, 6, 7),     // top    (+Z)
        SIMD3(0, 1, 5), SIMD3(0, 5, 4),     // front  (-Y)
        SIMD3(3, 7, 6), SIMD3(3, 6, 2),     // back   (+Y)
        SIMD3(0, 4, 7), SIMD3(0, 7, 3),     // left   (-X)
        SIMD3(1, 2, 6), SIMD3(1, 6, 5),     // right  (+X)
    ]

    static func boxPositions(min mn: SIMD3<Double>, max mx: SIMD3<Double>) -> [SIMD3<Double>] {
        [
            SIMD3(mn.x, mn.y, mn.z), SIMD3(mx.x, mn.y, mn.z),
            SIMD3(mx.x, mx.y, mn.z), SIMD3(mn.x, mx.y, mn.z),
            SIMD3(mn.x, mn.y, mx.z), SIMD3(mx.x, mn.y, mx.z),
            SIMD3(mx.x, mx.y, mx.z), SIMD3(mn.x, mx.y, mx.z),
        ]
    }

    /// Unit cube, corner at origin, Z-up. 8 vertices, 12 triangles, 18 edges.
    static func cube() -> Mesh {
        try! Mesh(positions: boxPositions(min: .zero, max: SIMD3(1, 1, 1)),
                  triangles: boxTriangles)
    }

    /// The cube expanded to raw triangle soup (36 vertices), as an STL would
    /// deliver it. Welding this back must recover the 8-vertex cube.
    static func cubeSoup() -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] {
        soup(of: cube())
    }

    static func soup(of mesh: Mesh) -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] {
        mesh.triangles.map {
            (mesh.positions[$0.x], mesh.positions[$0.y], mesh.positions[$0.z])
        }
    }

    /// Capped cylinder, axis along Z from z = 0 to z = height, centered on the
    /// Z axis. Cap fans around center vertices.
    static func cylinder(radius: Double = 1, height: Double = 2, radialSegments n: Int = 24) -> Mesh {
        var positions: [SIMD3<Double>] = []
        for i in 0..<n {  // bottom ring: 0..<n
            // Core's deterministic degree-domain trig, NOT Foundation's:
            // glibc and Apple libm differ in last ulps, and near-tangent
            // views (cylinder top) amplify that into flipped sample verdicts.
            // This keeps the fixture — and its goldens — bit-identical on
            // macOS and Linux.
            let angle = Double(i) * 360 / Double(n)
            positions.append(SIMD3(radius * cosDegrees(angle), radius * sinDegrees(angle), 0))
        }
        for i in 0..<n {  // top ring: n..<2n
            positions.append(SIMD3(positions[i].x, positions[i].y, height))
        }
        let bottomCenter = positions.count      // 2n
        positions.append(SIMD3(0, 0, 0))
        let topCenter = positions.count         // 2n + 1
        positions.append(SIMD3(0, 0, height))

        var triangles: [SIMD3<Int>] = []
        for i in 0..<n {
            let j = (i + 1) % n
            triangles.append(SIMD3(i, j, n + j))            // side, outward
            triangles.append(SIMD3(i, n + j, n + i))
            triangles.append(SIMD3(bottomCenter, j, i))     // bottom cap (-Z)
            triangles.append(SIMD3(topCenter, n + i, n + j)) // top cap (+Z)
        }
        return try! Mesh(positions: positions, triangles: triangles)
    }

    /// Near box (y ∈ [0, 1]) partially occluding a far box (y ∈ [3, 4]) in the
    /// front view (forward +Y): screen footprints overlap on [0.5, 1]².
    static func twoOffsetBoxes() -> Mesh {
        let near = boxPositions(min: .zero, max: SIMD3(1, 1, 1))
        let far = boxPositions(min: SIMD3(0.5, 3, 0.5), max: SIMD3(1.5, 4, 1.5))
        let triangles = boxTriangles + boxTriangles.map { $0 &+ SIMD3(8, 8, 8) }
        return try! Mesh(positions: near + far, triangles: triangles)
    }

    /// L-shaped extrusion (cross-section in XZ, extruded along Y by 1):
    /// bottom bar 2 × 0.5, upright 0.5 × 2. Every edge is manifold — the cap
    /// triangulation uses all 7 outline vertices, so no T-junctions.
    static func lBracket() -> Mesh {
        // Outline in (x, z), CCW as seen from -Y (the front view).
        // Index 6 = (0, 0.5) splits the collinear left side deliberately.
        let outline: [(Double, Double)] = [
            (0, 0), (2, 0), (2, 0.5), (0.5, 0.5), (0.5, 2), (0, 2), (0, 0.5),
        ]
        let n = outline.count  // 7
        let depth = 1.0

        var positions: [SIMD3<Double>] = []
        positions += outline.map { SIMD3($0.0, 0, $0.1) }      // front: 0..<7
        positions += outline.map { SIMD3($0.0, depth, $0.1) }  // back: 7..<14

        // Ear-clipped L polygon over outline indices, CCW in (x, z).
        let capTriangles: [SIMD3<Int>] = [
            SIMD3(0, 1, 2), SIMD3(0, 2, 3), SIMD3(0, 3, 6),
            SIMD3(6, 3, 4), SIMD3(6, 4, 5),
        ]

        var triangles: [SIMD3<Int>] = []
        // Front cap at y = 0: CCW in (x, z) ⇒ outward -Y.
        triangles += capTriangles
        // Back cap at y = depth: reversed winding ⇒ outward +Y.
        triangles += capTriangles.map { SIMD3($0.x + n, $0.z + n, $0.y + n) }
        // Walls, one quad per outline segment.
        for i in 0..<n {
            let j = (i + 1) % n
            triangles.append(SIMD3(i, n + i, n + j))
            triangles.append(SIMD3(i, n + j, j))
        }
        return try! Mesh(positions: positions, triangles: triangles)
    }

    /// Unit cube with each face subdivided into perSide × perSide quads
    /// (12 × perSide² triangles) — the performance-smoke mesh. Vertices are
    /// deduplicated via exact integer grid keys, so the mesh is closed and
    /// manifold; the only candidate edges are the 12 original cube edges.
    static func subdividedCube(perSide k: Int) -> Mesh {
        var vertexIndex: [SIMD3<Int>: Int] = [:]
        var positions: [SIMD3<Double>] = []
        var triangles: [SIMD3<Int>] = []

        func vertex(_ g: SIMD3<Int>) -> Int {
            if let existing = vertexIndex[g] { return existing }
            let index = positions.count
            vertexIndex[g] = index
            positions.append(SIMD3(Double(g.x), Double(g.y), Double(g.z)) / Double(k))
            return index
        }

        // (origin, uAxis, vAxis) per face, with cross(u, v) pointing outward.
        let faces: [(SIMD3<Int>, SIMD3<Int>, SIMD3<Int>)] = [
            (SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),  // bottom -Z
            (SIMD3(0, 0, k), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),  // top    +Z
            (SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),  // front  -Y
            (SIMD3(0, k, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),  // back   +Y
            (SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),  // left   -X
            (SIMD3(k, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),  // right  +X
        ]
        for (origin, u, v) in faces {
            for i in 0..<k {
                for j in 0..<k {
                    let c00 = vertex(origin &+ i &* u &+ j &* v)
                    let c10 = vertex(origin &+ (i + 1) &* u &+ j &* v)
                    let c11 = vertex(origin &+ (i + 1) &* u &+ (j + 1) &* v)
                    let c01 = vertex(origin &+ i &* u &+ (j + 1) &* v)
                    triangles.append(SIMD3(c00, c10, c11))
                    triangles.append(SIMD3(c00, c11, c01))
                }
            }
        }
        return try! Mesh(positions: positions, triangles: triangles)
    }

    /// Signed volume via the divergence theorem: positive iff the mesh is
    /// closed and consistently outward-wound. Cheap winding sanity check.
    static func signedVolume(of mesh: Mesh) -> Double {
        var six = 0.0
        for t in mesh.triangles {
            let p0 = mesh.positions[t.x]
            let p1 = mesh.positions[t.y]
            let p2 = mesh.positions[t.z]
            six += dot(p0, cross(p1, p2))
        }
        return six / 6
    }
}
