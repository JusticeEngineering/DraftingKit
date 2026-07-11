// Occlusion testing (pipeline stage 4.5): a sample (x, y, depth) is hidden
// iff some projected triangle contains (x, y), interpolates to a depth more
// than ε in front of the sample, and is not one of the sampled edge's own
// adjacent faces. No backface culling — open meshes must occlude from behind.
// Accelerated by a BVH over projected-triangle AABBs, built once per view.
//
// BVH rather than a uniform grid: wild meshes mix huge and tiny triangles,
// which degrades grids badly, and the BVH needs no cell-size tuning; the M4
// performance smoke benchmarks the choice.

/// One projected triangle, prepared for fast point queries.
/// Vertices are stored CCW in screen space (flipped at build if needed) so
/// containment is simply "all edge crosses ≥ 0". Inclusive boundaries: a
/// sample exactly on a projected edge counts as contained — the depth
/// epsilon then decides, which keeps coincident-surface cases stable.
struct OccluderTriangle: Sendable {
    var a: SIMD2<Double>
    var b: SIMD2<Double>
    var c: SIMD2<Double>
    var depths: SIMD3<Double>   // at a, b, c
    var doubleArea: Double      // 2 × projected area, > 0 (CCW)
    var minDepth: Double
    var faceIndex: Int          // original mesh triangle index

    /// True if this triangle occludes `sample` = (x, y, depth).
    @inline(__always)
    func occludes(_ sample: SIMD3<Double>, epsilon: Double) -> Bool {
        // Cheapest rejection first: can't be strictly in front of the sample.
        if minDepth >= sample.z - epsilon { return false }
        let p = SIMD2(sample.x, sample.y)
        let wa = cross(b - p, c - p)
        if wa < 0 { return false }
        let wb = cross(c - p, a - p)
        if wb < 0 { return false }
        let wc = cross(a - p, b - p)
        if wc < 0 { return false }
        // Barycentric depth interpolation (orthographic ⇒ linear in screen).
        let interpolated = (wa * depths.x + wb * depths.y + wc * depths.z) / doubleArea
        return interpolated < sample.z - epsilon
    }
}

/// Flat-array BVH over projected triangle AABBs. Build is deterministic:
/// median split on the wider centroid axis, ties broken by triangle index.
struct BVH: Sendable, Equatable {
    struct Node: Sendable, Equatable {
        var minX: Double, minY: Double, maxX: Double, maxY: Double
        var left: Int32     // inner: left child node index; leaf: -1
        var right: Int32    // inner: right child node index; leaf: -1
        var start: Int32    // leaf: first index into order; inner: -1
        var count: Int32    // leaf: number of items; inner: 0

        @inline(__always)
        func contains(_ x: Double, _ y: Double) -> Bool {
            x >= minX && x <= maxX && y >= minY && y <= maxY
        }
    }

    private(set) var nodes: [Node] = []
    /// Item indices, grouped by leaf.
    private(set) var order: [Int] = []

    static let leafSize = 4

    /// Builds over one AABB (min.x, min.y, max.x, max.y) per item.
    init(boxes: [SIMD4<Double>]) {
        guard !boxes.isEmpty else { return }
        order = Array(boxes.indices)
        let centroids = boxes.map { SIMD2(($0.x + $0.z) * 0.5, ($0.y + $0.w) * 0.5) }
        nodes.reserveCapacity(2 * boxes.count / BVH.leafSize + 1)
        _ = build(boxes: boxes, centroids: centroids, range: 0..<order.count)
    }

    private mutating func build(boxes: [SIMD4<Double>],
                                centroids: [SIMD2<Double>],
                                range: Range<Int>) -> Int32 {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var cMin = SIMD2<Double>(.infinity, .infinity)
        var cMax = SIMD2<Double>(-.infinity, -.infinity)
        for i in range {
            let box = boxes[order[i]]
            minX = Swift.min(minX, box.x); minY = Swift.min(minY, box.y)
            maxX = Swift.max(maxX, box.z); maxY = Swift.max(maxY, box.w)
            cMin = pointwiseMin(cMin, centroids[order[i]])
            cMax = pointwiseMax(cMax, centroids[order[i]])
        }

        let nodeIndex = Int32(nodes.count)
        nodes.append(Node(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                          left: -1, right: -1,
                          start: Int32(range.lowerBound), count: Int32(range.count)))
        if range.count <= BVH.leafSize { return nodeIndex }

        // Median split on the wider centroid axis; deterministic tie-break.
        let extent = cMax - cMin
        let axis = extent.x >= extent.y ? 0 : 1
        order[range].sort { lhs, rhs in
            (centroids[lhs][axis], lhs) < (centroids[rhs][axis], rhs)
        }
        let mid = range.lowerBound + range.count / 2

        let left = build(boxes: boxes, centroids: centroids, range: range.lowerBound..<mid)
        let right = build(boxes: boxes, centroids: centroids, range: mid..<range.upperBound)
        nodes[Int(nodeIndex)].left = left
        nodes[Int(nodeIndex)].right = right
        nodes[Int(nodeIndex)].start = -1
        nodes[Int(nodeIndex)].count = 0
        return nodeIndex
    }

    /// Appends the item indices of every leaf whose AABB intersects `box`
    /// (min.x, min.y, max.x, max.y). Traversal order is fixed → deterministic.
    func collectIntersecting(_ box: SIMD4<Double>, into result: inout [Int]) {
        guard !nodes.isEmpty else { return }
        collect(node: 0, box: box, into: &result)
    }

    private func collect(node index: Int32, box: SIMD4<Double>, into result: inout [Int]) {
        let node = nodes[Int(index)]
        guard box.x <= node.maxX, box.z >= node.minX,
              box.y <= node.maxY, box.w >= node.minY else { return }
        if node.left < 0 {
            for i in Int(node.start)..<Int(node.start + node.count) {
                result.append(order[i])
            }
            return
        }
        collect(node: node.left, box: box, into: &result)
        collect(node: node.right, box: box, into: &result)
    }
}

/// Prepared per-view occlusion query structure (Sendable: shared read-only
/// across the M4 TaskGroup).
struct OcclusionTester: Sendable {
    private let occluders: [OccluderTriangle]
    private let bvh: BVH
    private let epsilon: Double

    /// Projects every mesh triangle and keeps those that can occlude:
    /// projected area ≥ tolerances.minOccluderArea (near-edge-on triangles
    /// contribute noise, not occlusion).
    init(mesh: Mesh, projected: [SIMD3<Double>], tolerances: Tolerances) {
        var occluders: [OccluderTriangle] = []
        occluders.reserveCapacity(mesh.triangles.count)
        for (faceIndex, t) in mesh.triangles.enumerated() {
            let pa = projected[t.x], pb = projected[t.y], pc = projected[t.z]
            var a = SIMD2(pa.x, pa.y), b = SIMD2(pb.x, pb.y), c = SIMD2(pc.x, pc.y)
            var depths = SIMD3(pa.z, pb.z, pc.z)
            var doubleArea = cross(b - a, c - a)
            if doubleArea < 0 {
                swap(&b, &c)
                depths = SIMD3(depths.x, depths.z, depths.y)
                doubleArea = -doubleArea
            }
            if doubleArea / 2 < tolerances.minOccluderArea { continue }
            occluders.append(OccluderTriangle(
                a: a, b: b, c: c,
                depths: depths,
                doubleArea: doubleArea,
                minDepth: depths.min(),
                faceIndex: faceIndex
            ))
        }
        self.occluders = occluders
        self.bvh = BVH(boxes: occluders.map {
            SIMD4(Swift.min($0.a.x, $0.b.x, $0.c.x), Swift.min($0.a.y, $0.b.y, $0.c.y),
                  Swift.max($0.a.x, $0.b.x, $0.c.x), Swift.max($0.a.y, $0.b.y, $0.c.y))
        })
        self.epsilon = tolerances.depthEpsilon
    }

    /// Occlusion test per SPEC §4.5. `ownFaces` are the sampled edge's
    /// adjacent mesh triangle indices (an edge lies on its faces and would
    /// self-occlude otherwise).
    func isHidden(_ sample: SIMD3<Double>, ownFaces: [Int]) -> Bool {
        guard !bvh.nodes.isEmpty else { return false }
        return query(node: 0, sample: sample, ownFaces: ownFaces)
    }

    private func query(node index: Int32, sample: SIMD3<Double>, ownFaces: [Int]) -> Bool {
        let node = bvh.nodes[Int(index)]
        guard node.contains(sample.x, sample.y) else { return false }
        if node.left < 0 {
            for i in Int(node.start)..<Int(node.start + node.count) {
                let triangle = occluders[bvh.order[i]]
                if ownFaces.contains(triangle.faceIndex) { continue }
                if triangle.occludes(sample, epsilon: epsilon) { return true }
            }
            return false
        }
        return query(node: node.left, sample: sample, ownFaces: ownFaces)
            || query(node: node.right, sample: sample, ownFaces: ownFaces)
    }

    /// Reference implementation without the BVH — used by tests to verify
    /// the accelerated path (debug hook, not part of the pipeline).
    func bruteForceIsHidden(_ sample: SIMD3<Double>, ownFaces: [Int]) -> Bool {
        occluders.contains { triangle in
            !ownFaces.contains(triangle.faceIndex) && triangle.occludes(sample, epsilon: epsilon)
        }
    }

    var occluderCount: Int { occluders.count }
}
