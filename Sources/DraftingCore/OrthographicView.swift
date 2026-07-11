// Orthographic view and its screen basis — pipeline stage 4.3 uses this
// exactly as specified in SPEC.md §3 (tests depend on the basis definition):
//
//   right   = normalize(forward × up)
//   trueUp  = right × forward
//   screenX = dot(p, right); screenY = dot(p, trueUp); depth = dot(p, forward)
//
// Smaller depth = closer to the viewer.

/// Orthographic view. `forward` points FROM the viewer INTO the scene.
public struct OrthographicView: Sendable {
    /// Unit view direction, into the scene.
    public let forward: SIMD3<Double>
    /// Unit up hint, not parallel to `forward` (sanitized at init).
    public let up: SIMD3<Double>

    /// Precomputed screen basis (unit, mutually orthogonal).
    let right: SIMD3<Double>
    let trueUp: SIMD3<Double>

    /// Inputs are normalized defensively. A zero `forward` falls back to the
    /// front view direction; an `up` (near-)parallel to `forward` falls back
    /// to the world axis least aligned with `forward` — never fails.
    public init(forward: SIMD3<Double>, up: SIMD3<Double>) {
        var f = normalize(forward)
        if f == .zero { f = SIMD3(0, 1, 0) }

        var u = normalize(up)
        var r = cross(f, u)
        if lengthSquared(r) < 1e-12 {
            // Degenerate up: pick the world axis least aligned with forward.
            let axes = [SIMD3<Double>(0, 0, 1), SIMD3<Double>(0, 1, 0), SIMD3<Double>(1, 0, 0)]
            u = axes.min { abs(dot($0, f)) < abs(dot($1, f)) }!
            r = cross(f, u)
        }

        self.forward = f
        self.right = normalize(r)
        self.trueUp = cross(self.right, f)  // unit: right ⊥ forward
        self.up = u
    }

    /// Projects a model-space point into (screenX, screenY, depth).
    @inline(__always)
    func project(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(dot(p, right), dot(p, trueUp), dot(p, forward))
    }

    // MARK: Named views (Z-up models, the 3D-printing / maker convention)

    /// Viewer at -Y looking +Y (screen x = world x, screen y = world z).
    public static let front = OrthographicView(forward: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1))
    /// Viewer at +Y looking -Y.
    public static let back = OrthographicView(forward: SIMD3(0, -1, 0), up: SIMD3(0, 0, 1))
    /// Viewer at +X looking -X.
    public static let right = OrthographicView(forward: SIMD3(-1, 0, 0), up: SIMD3(0, 0, 1))
    /// Viewer at -X looking +X.
    public static let left = OrthographicView(forward: SIMD3(1, 0, 0), up: SIMD3(0, 0, 1))
    /// Viewer above looking down (screen x = world x, screen y = world y).
    public static let top = OrthographicView(forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
    /// Viewer below looking up.
    public static let bottom = OrthographicView(forward: SIMD3(0, 0, 1), up: SIMD3(0, 1, 0))

    /// Viewer up-front-right of a Z-up model.
    public static let isometric = OrthographicView(forward: SIMD3(-1, 1, -1), up: SIMD3(0, 0, 1))
}
