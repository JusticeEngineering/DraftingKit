// Mesh: indexed triangle mesh with precomputed edge adjacency and face
// normals — pipeline stage 4.1 (weld & adjacency) lives here, at construction.

/// Errors thrown by the validating `Mesh` initializer.
public enum MeshError: Error, Sendable, Equatable {
    case invalidIndex
    case emptyMesh
}

/// Counters describing what construction had to tolerate. Wild-caught STLs are
/// filthy; the library degrades gracefully and records what it saw here.
public struct MeshDiagnostics: Sendable, Equatable {
    /// Triangles in the incoming soup, before any dropping.
    public var inputTriangleCount: Int
    /// Vertices referenced by surviving triangles after welding.
    public var weldedVertexCount: Int
    /// Triangles dropped during welding: zero area, a repeated vertex after
    /// welding, or a non-finite coordinate.
    public var degenerateTrianglesDropped: Int
    /// Edges with ≥ 3 adjacent faces.
    public var nonManifoldEdgeCount: Int
    /// Edges with exactly 1 adjacent face.
    public var boundaryEdgeCount: Int

    /// Creates diagnostics (all counters default to zero).
    public init(inputTriangleCount: Int = 0,
                weldedVertexCount: Int = 0,
                degenerateTrianglesDropped: Int = 0,
                nonManifoldEdgeCount: Int = 0,
                boundaryEdgeCount: Int = 0) {
        self.inputTriangleCount = inputTriangleCount
        self.weldedVertexCount = weldedVertexCount
        self.degenerateTrianglesDropped = degenerateTrianglesDropped
        self.nonManifoldEdgeCount = nonManifoldEdgeCount
        self.boundaryEdgeCount = boundaryEdgeCount
    }
}

/// A unique undirected edge of the mesh, with the faces that share it.
/// Internal: consumed by per-view classification (stage 4.2).
struct MeshEdge: Sendable, Equatable {
    /// Vertex indices, a < b.
    var a: Int
    var b: Int
    /// Adjacent face indices, ascending.
    var faces: [Int]
}

/// Axis-aligned 3D box (the 3D sibling of `Rect2D` — a nominal type so it
/// can be extended and conform, unlike a tuple).
public struct Box3D: Sendable, Codable, Equatable {
    /// Minimum corner.
    public var min: SIMD3<Double>
    /// Maximum corner.
    public var max: SIMD3<Double>

    /// Creates a box from its corners (not validated).
    public init(min: SIMD3<Double>, max: SIMD3<Double>) {
        self.min = min
        self.max = max
    }

    /// Extent per axis (`max - min`).
    public var size: SIMD3<Double> { max - min }

    /// Corner-to-corner length — the usual "model size" scalar.
    public var diagonal: Double { length(size) }
}

/// An indexed triangle mesh with precomputed edge adjacency and face
/// normals. Construct once per model (welding dominates import cost) and
/// reuse across views.
public struct Mesh: Sendable {
    /// Vertex positions, in model units.
    public let positions: [SIMD3<Double>]
    /// Vertex indices into `positions`, three per triangle.
    public let triangles: [SIMD3<Int>]
    /// What construction had to tolerate (weld results, degenerate drops,
    /// boundary and non-manifold edge counts).
    public let diagnostics: MeshDiagnostics

    /// Unit face normals, one per triangle (zero vector for a degenerate
    /// triangle that survived the validating init).
    let faceNormals: [SIMD3<Double>]
    /// Unique edges sorted by (a, b) — a canonical, deterministic order.
    let edges: [MeshEdge]

    /// Axis-aligned bounds over `positions` (zero for an empty mesh).
    public var boundingBox: Box3D {
        guard var mn = positions.first else { return Box3D(min: .zero, max: .zero) }
        var mx = mn
        for p in positions {
            mn = pointwiseMin(mn, p)
            mx = pointwiseMax(mx, p)
        }
        return Box3D(min: mn, max: mx)
    }

    /// Length of the bounding box diagonal — the model's size scale,
    /// which tolerance defaults derive from.
    public var boundingDiagonal: Double { boundingBox.diagonal }

    /// Validating init. Throws `MeshError.invalidIndex` if any index is out of
    /// range, `MeshError.emptyMesh` if there are no triangles.
    public init(positions: [SIMD3<Double>], triangles: [SIMD3<Int>]) throws {
        guard !positions.isEmpty, !triangles.isEmpty else { throw MeshError.emptyMesh }
        for t in triangles {
            for lane in 0..<3 where t[lane] < 0 || t[lane] >= positions.count {
                throw MeshError.invalidIndex
            }
        }
        self.positions = positions
        self.triangles = triangles
        (self.faceNormals, self.edges) = Mesh.buildTopology(positions: positions, triangles: triangles)
        self.diagnostics = MeshDiagnostics(
            inputTriangleCount: triangles.count,
            weldedVertexCount: positions.count,
            degenerateTrianglesDropped: 0,
            nonManifoldEdgeCount: edges.count { $0.faces.count >= 3 },
            boundaryEdgeCount: edges.count { $0.faces.count == 1 }
        )
    }

    /// Weld raw triangle soup (e.g. from STL) into an indexed mesh.
    ///
    /// - Parameter tolerance: absolute distance below which vertices merge.
    ///   Callers typically pass a fraction of the soup's bounding diagonal
    ///   (1e-6 is a good default).
    ///
    /// Degenerate triangles (zero area after welding, or containing non-finite
    /// coordinates) are dropped and counted in the mesh's `diagnostics`.
    /// Never throws: an empty or fully-degenerate soup yields an empty mesh,
    /// visible in the diagnostics.
    public init(weldingSoup soup: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)],
                tolerance: Double) {
        var welder = VertexWelder(tolerance: tolerance)
        var positions: [SIMD3<Double>] = []
        var triangles: [SIMD3<Int>] = []
        triangles.reserveCapacity(soup.count)
        var dropped = 0

        for (p0, p1, p2) in soup {
            guard isFinite(p0), isFinite(p1), isFinite(p2) else {
                dropped += 1
                continue
            }
            let i0 = welder.index(for: p0, positions: &positions)
            let i1 = welder.index(for: p1, positions: &positions)
            let i2 = welder.index(for: p2, positions: &positions)
            // Degenerate after welding: repeated vertex or zero area.
            if i0 == i1 || i1 == i2 || i0 == i2 {
                dropped += 1
                continue
            }
            let n = cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            if lengthSquared(n) == 0 {
                dropped += 1
                continue
            }
            triangles.append(SIMD3(i0, i1, i2))
        }

        // Compact away vertices referenced only by dropped triangles — orphans
        // would silently inflate boundingBox, which downstream tolerances
        // derive from. Remap in first-use order to stay deterministic.
        var remap = [Int](repeating: -1, count: positions.count)
        var compacted: [SIMD3<Double>] = []
        compacted.reserveCapacity(positions.count)
        for i in 0..<triangles.count {
            var t = triangles[i]
            for lane in 0..<3 {
                let old = t[lane]
                if remap[old] == -1 {
                    remap[old] = compacted.count
                    compacted.append(positions[old])
                }
                t[lane] = remap[old]
            }
            triangles[i] = t
        }

        self.positions = compacted
        self.triangles = triangles
        (self.faceNormals, self.edges) = Mesh.buildTopology(positions: compacted, triangles: triangles)

        self.diagnostics = MeshDiagnostics(
            inputTriangleCount: soup.count,
            weldedVertexCount: compacted.count,
            degenerateTrianglesDropped: dropped,
            nonManifoldEdgeCount: edges.count { $0.faces.count >= 3 },
            boundaryEdgeCount: edges.count { $0.faces.count == 1 }
        )
    }

    // MARK: Topology

    private struct EdgeKey: Hashable {
        var a: Int
        var b: Int
        init(_ i: Int, _ j: Int) {
            if i < j { a = i; b = j } else { a = j; b = i }
        }
    }

    private static func buildTopology(positions: [SIMD3<Double>],
                                      triangles: [SIMD3<Int>])
        -> (normals: [SIMD3<Double>], edges: [MeshEdge])
    {
        var normals = [SIMD3<Double>]()
        normals.reserveCapacity(triangles.count)

        // Dictionary is used only as an accumulator keyed by vertex pair; the
        // final edge list is canonically sorted so no hash-iteration order can
        // leak into anything downstream (constraint C3).
        var adjacency: [EdgeKey: [Int]] = [:]
        adjacency.reserveCapacity(triangles.count * 3 / 2)

        for (faceIndex, t) in triangles.enumerated() {
            let p0 = positions[t.x], p1 = positions[t.y], p2 = positions[t.z]
            normals.append(normalize(cross(p1 - p0, p2 - p0)))

            // Face indices arrive in ascending order, so each list stays sorted.
            adjacency[EdgeKey(t.x, t.y), default: []].append(faceIndex)
            adjacency[EdgeKey(t.y, t.z), default: []].append(faceIndex)
            adjacency[EdgeKey(t.z, t.x), default: []].append(faceIndex)
        }

        var edges = adjacency.map { MeshEdge(a: $0.key.a, b: $0.key.b, faces: $0.value) }
        edges.sort { ($0.a, $0.b) < ($1.a, $1.b) }
        return (normals, edges)
    }
}

/// Spatial-hash vertex welder: quantizes positions to a grid of `tolerance`
/// and merges any incoming vertex with an existing one closer than
/// `tolerance` (checking the 26 neighboring cells so near-boundary vertices
/// merge correctly). First-appearance order of surviving vertices makes the
/// result deterministic.
private struct VertexWelder {
    private struct Cell: Hashable {
        var x: Int64
        var y: Int64
        var z: Int64
    }

    private let tolerance: Double
    private let toleranceSquared: Double
    private var grid: [Cell: [Int]] = [:]

    init(tolerance: Double) {
        // A non-positive tolerance still welds exactly-equal vertices.
        self.tolerance = tolerance > 0 ? tolerance : Double.leastNormalMagnitude
        self.toleranceSquared = max(tolerance, 0) * max(tolerance, 0)
    }

    private func cell(for p: SIMD3<Double>) -> Cell {
        // gridCell clamps, so a tiny tolerance on large coordinates can't
        // overflow Int64. Clamped cells stop merging across the clamp
        // boundary — graceful degradation, not a crash.
        Cell(x: gridCell(p.x, tolerance), y: gridCell(p.y, tolerance), z: gridCell(p.z, tolerance))
    }

    mutating func index(for p: SIMD3<Double>, positions: inout [SIMD3<Double>]) -> Int {
        let home = cell(for: p)
        // Fixed -1...1 scan order keeps candidate lookup deterministic.
        let offsets: ClosedRange<Int64> = -1...1
        for dx in offsets {
            for dy in offsets {
                for dz in offsets {
                    let neighbor = Cell(x: home.x &+ dx, y: home.y &+ dy, z: home.z &+ dz)
                    guard let candidates = grid[neighbor] else { continue }
                    for index in candidates
                    where distanceSquared(positions[index], p) <= toleranceSquared {
                        return index
                    }
                }
            }
        }
        let index = positions.count
        positions.append(p)
        grid[home, default: []].append(index)
        return index
    }
}
