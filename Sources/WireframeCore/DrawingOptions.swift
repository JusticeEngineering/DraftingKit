// User-facing knobs for makeLineDrawing, exactly per SPEC.md §3.

public struct DrawingOptions: Sendable {
    /// Dihedral angle above which a shared edge is drawn as a crease.
    public var creaseAngleDegrees: Double = 30
    /// Emit hidden (occluded) lines as .hidden paths.
    public var includeHiddenLines: Bool = true
    /// Drop hidden segments that coincide with a visible segment
    /// (e.g. a cube's back edges projecting exactly onto its front edges).
    public var suppressHiddenCoincidentWithVisible: Bool = true
    /// Visibility sample spacing as a fraction of the *projected* bounding diagonal.
    public var sampleSpacingFraction: Double = 1.0 / 512.0
    /// Occlusion depth epsilon as a fraction of the model bounding diagonal.
    public var epsilonFraction: Double = 1e-6
    public init() {}
}

/// Every numeric tolerance the pipeline stages use, derived in ONE place from
/// the options + model/projection size (working agreement §10 — no magic
/// numbers scattered through stage code).
struct Tolerances: Sendable {
    /// Visibility sample spacing `s`, in projected model units.
    var sampleSpacing: Double
    /// Candidates with projected length below this are dots, not lines (4.2).
    var minProjectedEdgeLength: Double
    /// Occlusion depth epsilon ε (4.5).
    var depthEpsilon: Double
    /// Visibility transition bisection stops below this interval (4.4).
    var bisectionTolerance: Double
    /// Chaining: endpoints within this merge (4.6).
    var chainEndpointTolerance: Double
    /// Coincidence suppression distance (4.6).
    var coincidenceTolerance: Double
    /// Occluders with projected area below s² don't count (4.5).
    var minOccluderArea: Double
    /// Chaining: |cross| of unit directions below this is collinear (4.6).
    var chainDirectionCross: Double
    /// |dot(normal, forward)| below this is its own sign class (4.2).
    var grazingDot: Double
    /// dot(n1, n2) below this ⇒ dihedral angle exceeds the crease angle.
    var creaseCosineThreshold: Double

    init(options: DrawingOptions, modelDiagonal: Double, projectedDiagonal: Double) {
        let s = options.sampleSpacingFraction * projectedDiagonal
        sampleSpacing = s
        minProjectedEdgeLength = 2 * s
        depthEpsilon = options.epsilonFraction * modelDiagonal
        bisectionTolerance = s / 256
        chainEndpointTolerance = s / 16
        coincidenceTolerance = s / 4
        minOccluderArea = s * s
        chainDirectionCross = 1e-9
        grazingDot = 1e-12
        creaseCosineThreshold = cosDegrees(options.creaseAngleDegrees)
    }
}
