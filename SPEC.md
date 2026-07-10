# WireframeKit — Build Specification

You are building **WireframeKit**, a Swift library that converts 3D triangle meshes (STL/OBJ/USDZ) into 2D hidden-line-removed vector line drawings. It will be consumed by the host macOS app (a plan-sheet / drawing document tool, Swift/SwiftUI + AppKit) which places the resulting drawing as a scale-accurate image element on a document sheet. The library may be open-sourced later, which drives several hard constraints below (purity, no external deps, clean-room implementation, MIT license from day one).

Work **milestone by milestone** (§9). Each milestone ends with `swift test` green, a short summary of what was built, and any proposed deviations from this spec — propose deviations explicitly, never deviate silently. Stop after each milestone for review.

---

## 1. Purpose & consumption contract

**Input:** a triangle mesh + an orthographic view + options.
**Output:** a `LineDrawing` — classified 2D polylines (visible / hidden) plus exact bounds, all in **model units**.

**How the host app consumes it (this contract shapes the API — do not break it):**

1. User imports an STL/OBJ; app asks the user what one model unit means (mm, inch — STL is unitless; the library stays unit-agnostic and never interprets units).
2. User picks a view (front/top/right/iso/custom) and options.
3. App calls `makeLineDrawing(mesh:view:options:)` → `LineDrawing`.
4. App calls `lineDrawing.pdfData(style:)` (WireframeGraphics target) → PDF `Data`, hands it to `NSImage(data:)`, and places it as a regular image element. PDF-backed `NSImage` draws vector-sharp at any zoom.
5. Scale-accurate placement: the PDF's media box is `bounds × style.pointsPerModelUnit` (+ margins). The app computes `pointsPerModelUnit` from the user's chosen scale and units. Worked example: model in mm placed at 1:4 → `pointsPerModelUnit = (72 / 25.4) / 4 ≈ 0.7087`.

Therefore: `bounds` must be **exact** over all emitted geometry, the PDF media box math must be trustworthy, and output must be **deterministic** (identical input + options → identical output, byte-for-byte after canonical ordering, regardless of parallelism).

---

## 2. Package layout & hard constraints

Local SwiftPM package, referenced by path from the app repo (e.g. `Packages/WireframeKit`).

```
WireframeKit/
├── Package.swift                  // swift-tools-version: 6.0
├── SPEC.md                        // this file
├── LICENSE                        // MIT, © 2026 Justice Engineering
├── README.md                      // written in M6
├── Sources/
│   ├── WireframeCore/             // Swift stdlib ONLY — see constraints
│   ├── WireframeModelIO/          // Apple-only: ModelIO ingest (.obj/.usdz/.stl)
│   └── WireframeGraphics/         // Apple-only: CoreGraphics → CGPath, PDF Data
└── Tests/
    ├── WireframeCoreTests/        // runs on macOS AND Linux
    │   └── Goldens/               // committed JSON + SVG golden files
    ├── WireframeModelIOTests/     // macOS only; tiny STL/OBJ fixture files
    └── WireframeGraphicsTests/    // macOS only
```

Apple-only targets declare `.macOS(.v13)` (raise to match the app if it targets newer). `WireframeCore` declares no platform requirements.

**Hard constraints — enforce these throughout, re-verify at every milestone:**

- **C1. Core purity.** `Sources/WireframeCore` imports nothing beyond the Swift standard library. No Foundation, no simd module, no Dispatch. Vector math uses stdlib `SIMD2<Double>` / `SIMD3<Double>` (write the ~10 lines of cross/dot/normalize as internal helpers). File I/O is the caller's job — core APIs take `[UInt8]`, never URLs. Verify each milestone: `grep -rn "^import" Sources/WireframeCore` shows nothing (or only `import Swift`).
- **C2. Concurrency.** All public types are `Sendable` value types. The package builds clean under Swift 6 strict concurrency (language mode 6, no `@unchecked`, no warnings).
- **C3. Determinism.** Parallel stages write results into preallocated, index-addressed arrays (never unordered appends); output gets a canonical sort (§4.7). No `Set`/`Dictionary` iteration order may leak into output. A dedicated test runs the pipeline serial vs. parallel and asserts identical serialized output.
- **C4. Zero dependencies.** No SwiftPM dependencies, no vendored code. **Clean-room implementation from this spec only** — do not copy or translate code from any external project. (Context: the sampling design is informed by MIT-licensed prior art, which is fine as *design*; GPL implementations of similar algorithms exist and must not influence code at all.)
- **C5. API stability discipline.** The public API in §3 is the contract. Additions are fine; changes/removals must be called out in the milestone summary.

---

## 3. Public API — WireframeCore

Indices are `Int`. All coordinates `Double`. Everything below is `public` and `Sendable`.

```swift
// MARK: Geometry input

public struct Mesh: Sendable {
    public let positions: [SIMD3<Double>]
    public let triangles: [SIMD3<Int>]          // indices into positions
    public var boundingBox: (min: SIMD3<Double>, max: SIMD3<Double>) { get }
    public var boundingDiagonal: Double { get }

    /// Validating init. Throws MeshError.invalidIndex if any index is out of range.
    public init(positions: [SIMD3<Double>], triangles: [SIMD3<Int>]) throws

    /// Weld raw triangle soup (e.g. from STL) into an indexed mesh.
    /// - tolerance: absolute distance below which vertices merge.
    ///   Callers typically pass a fraction of the soup's bounding diagonal (1e-6 is a good default).
    /// Degenerate triangles (zero area after welding) are dropped and counted in diagnostics.
    public init(weldingSoup soup: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)],
                tolerance: Double,
                diagnostics: inout MeshDiagnostics)
}

public struct MeshDiagnostics: Sendable, Equatable {
    public var inputTriangleCount: Int
    public var weldedVertexCount: Int
    public var degenerateTrianglesDropped: Int
    public var nonManifoldEdgeCount: Int        // edges with ≥3 adjacent faces
    public var boundaryEdgeCount: Int           // edges with exactly 1 adjacent face
}

public enum MeshError: Error, Sendable { case invalidIndex, emptyMesh }

// MARK: STL parsing (core, so Linux CI can run end-to-end)

public enum STL {
    /// Parses binary or ASCII STL (autodetected) and welds it.
    /// weldToleranceFraction is relative to the soup's bounding diagonal.
    public static func parse(_ bytes: [UInt8],
                             weldToleranceFraction: Double = 1e-6,
                             diagnostics: inout MeshDiagnostics) throws -> Mesh
}

public enum STLError: Error, Sendable { case truncated, malformedASCII(line: Int), empty }

// MARK: View

/// Orthographic view. `forward` points FROM the viewer INTO the scene.
/// Screen basis (must be implemented exactly like this — tests depend on it):
///   right   = normalize(forward × up)
///   trueUp  = right × forward
///   screenX = dot(p, right); screenY = dot(p, trueUp); depth = dot(p, forward)
/// Smaller depth = closer to viewer.
public struct OrthographicView: Sendable {
    public let forward: SIMD3<Double>   // unit
    public let up: SIMD3<Double>        // unit, not parallel to forward
    public init(forward: SIMD3<Double>, up: SIMD3<Double>)

    // Named views assume Z-up models (the 3D-printing / maker convention).
    public static let front:  OrthographicView  // forward ( 0,  1,  0), up (0, 0, 1)
    public static let back:   OrthographicView  // forward ( 0, -1,  0), up (0, 0, 1)
    public static let right:  OrthographicView  // forward (-1,  0,  0), up (0, 0, 1)
    public static let left:   OrthographicView  // forward ( 1,  0,  0), up (0, 0, 1)
    public static let top:    OrthographicView  // forward ( 0,  0, -1), up (0, 1, 0)
    public static let bottom: OrthographicView  // forward ( 0,  0,  1), up (0, 1, 0)
    public static let isometric: OrthographicView
    // isometric: viewer up-front-right of a Z-up model:
    //   forward = normalize((-1, 1, -1)), up (0, 0, 1)
}

// MARK: Options

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
    public init()
}

// MARK: Output

public struct LineDrawing: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case visible, hidden }
    public struct Path: Sendable, Codable, Equatable {
        public var points: [SIMD2<Double>]      // ≥ 2 points; y is UP (math convention)
        public var kind: Kind
    }
    public var paths: [Path]
    /// Tight bounds over every point in `paths`, in model units.
    public var bounds: (min: SIMD2<Double>, max: SIMD2<Double>)
    // Note: tuple isn't Codable — implement Codable manually or use a small
    // public struct Rect2D { var min, max: SIMD2<Double> }. Prefer Rect2D.
}

// MARK: Entry point (pure function — same inputs, same output, always)

public func makeLineDrawing(mesh: Mesh,
                            view: OrthographicView,
                            options: DrawingOptions = .init()) -> LineDrawing

// MARK: SVG (debug / golden artifacts / free OSS win)

public extension LineDrawing {
    /// Y-flipped for SVG's y-down coordinate space. viewBox = bounds + margin.
    /// Visible: solid strokes. Hidden: dashed. Transparent background.
    func svg(strokeWidth: Double = 1.0,
             hiddenDashPattern: [Double] = [4, 3],
             margin: Double = 2.0) -> String
}
```

`SIMD2<Double>`/`SIMD3<Double>` conform to `Codable` in the stdlib, so `LineDrawing` serialization is nearly free.

---

## 4. Pipeline specification

Seven stages inside `makeLineDrawing`. Keep each stage a separate internal function with its own unit tests — the stages are the module boundaries.

**4.1 Weld & adjacency.** (Done at `Mesh` construction.) Quantize vertex positions to a grid of `tolerance` for welding (hash on quantized coordinates; also check the 26 neighboring cells so near-boundary vertices merge correctly). Drop zero-area triangles. Build edge adjacency: key = sorted vertex index pair → list of adjacent face indices. Precompute unit face normals. Edges with ≥3 faces are non-manifold: count them in diagnostics and treat them as always-drawn boundary edges (never fail — wild-caught STLs are filthy and the library must degrade gracefully).

**4.2 Per-view edge classification.** Let `f` = view forward. An edge is a **candidate** if any of: *boundary* (1 adjacent face); *crease* (2 faces, dihedral angle between normals > `creaseAngleDegrees`); *silhouette* (2 faces, `dot(n1, f)` and `dot(n2, f)` have strictly opposite signs; treat a near-zero dot, |·| < 1e-12, as its own sign class so grazing faces don't flip-flop). Skip candidates whose *projected* length < 2 × sample spacing (edges nearly parallel to the view axis contribute dots, not lines).

**4.3 Projection.** Using the basis in §3 exactly. Each candidate edge becomes a 2D segment with linearly interpolable depth. Compute the projected bounding diagonal here — sampling spacing derives from it.

**4.4 Visibility sampling.** For each candidate edge: place samples along the projected segment at spacing `s = sampleSpacingFraction × projectedDiagonal` (minimum 2 samples; sample at sub-interval midpoints, which sidesteps endpoint-on-vertex degeneracies). Occlusion-test each sample (§4.5). Where two adjacent samples disagree, bisect between them until the interval is < `s / 256`, yielding a crisp transition point. Assemble maximal runs into visible and hidden sub-segments. (This is the Appel insight implemented by sampling instead of exact 2D intersection — visibility only changes at a finite set of points, and bisection localizes them without any of the exact-arithmetic epsilon hell.)

**4.5 Occlusion test.** A sample `p = (x, y, depth)` is **hidden** iff some triangle (a) contains `(x, y)` in its 2D projection, (b) has interpolated depth at that point `< p.depth − ε` where `ε = epsilonFraction × modelBoundingDiagonal`, and (c) is **not** one of the edge's own adjacent faces (an edge lies on its faces and would self-occlude otherwise). No backface culling — open meshes (single-sided panels) must still occlude from behind. Exclude near-edge-on occluders: projected triangle area < `s²` doesn't count. Accelerate with a BVH (or uniform grid — implementer's choice, benchmark-justified) over projected triangle AABBs, built once per view.

**4.6 Chaining & coincidence suppression.** Within each kind, merge sub-segments that share an endpoint (within `s / 16`) **and** are collinear (cross product of directions below tolerance) into polylines; collapse collinear interior points. Do not chain across corners in v1 — corner-joining is cosmetic and can come later. Then, if `suppressHiddenCoincidentWithVisible`: drop any hidden sub-segment whose endpoints both lie within `s / 4` of some visible segment's supporting line *and* whose projection onto that segment overlaps it — this kills the classic cube-back-edges-under-front-edges dashes.

**4.7 Canonical ordering & emit.** Normalize each path's direction (start point = lexicographically smaller endpoint by (x, y)). Sort paths by (kind, start.x, start.y, end.x, end.y, point count). Compute `bounds` from the actual emitted points. This ordering is what makes C3 (determinism) testable.

**Parallelism.** Stages 4.2–4.5 are per-edge independent. Use a `TaskGroup` over edge-index chunks writing into a preallocated results array indexed by edge. Provide an internal serial path (an internal flag or environment hook) so the determinism test can compare serial vs. parallel output.

---

## 5. WireframeModelIO (Apple platforms)

```swift
import ModelIO

public enum MeshImport {
    /// Loads .obj / .usdz (and .stl, but see note) via MDLAsset, flattens all
    /// submeshes to triangles, welds, returns Mesh + diagnostics.
    public static func mesh(contentsOf url: URL,
                            weldToleranceFraction: Double = 1e-6,
                            diagnostics: inout MeshDiagnostics) throws -> Mesh
}
```

For `.stl` URLs, read the bytes and route through core's `STL.parse` (one parser, one behavior, testable on Linux); use `MDLAsset` for everything else. Convert whatever vertex/index formats ModelIO hands back (float/double, 16/32-bit indices, triangle strips → triangles).

---

## 6. WireframeGraphics (Apple platforms)

CoreGraphics only — no AppKit (the app owns `NSImage`; `NSImage(data: pdfData)` works directly).

```swift
import CoreGraphics

public struct PDFStyle: Sendable {
    /// PDF points per model unit. The app computes this from user scale + units.
    /// e.g. mm at 1:4 → (72 / 25.4) / 4 ≈ 0.7087.
    public var pointsPerModelUnit: Double
    public var visibleLineWidth: Double = 1.0     // PDF points, on paper
    public var hiddenLineWidth: Double = 0.75
    public var hiddenDashPattern: [Double] = [4, 3]
    public var margin: Double = 0                 // PDF points, added on all sides
    public init(pointsPerModelUnit: Double)
}

public extension LineDrawing {
    /// One CGPath per kind (model-space coordinates, y-up — PDF is y-up too,
    /// so unlike SVG there is NO flip).
    func cgPath(for kind: Kind) -> CGPath

    /// Single-page vector PDF. MediaBox = bounds.size × pointsPerModelUnit + 2×margin.
    /// Geometry is translated so bounds.min maps to (margin, margin).
    func pdfData(style: PDFStyle) -> Data
}
```

The media-box arithmetic is load-bearing for the app's scale-accurate placement — test it explicitly (§7).

---

## 7. Testing

Use the **Swift Testing** framework (`import Testing`). Fixtures and goldens are the backbone; write tests alongside or before implementation within each milestone.

**Procedural fixtures** (in `WireframeCoreTests`, code not files — readable and exact):

- `Fixtures.cube()` — unit cube, corner at origin, Z-up.
- `Fixtures.cylinder(radius:height:radialSegments: 24)` — axis along Z, capped.
- `Fixtures.twoOffsetBoxes()` — near box partially occluding a far box (front view).
- `Fixtures.lBracket()` — an L-shaped extrusion; creases + self-occlusion in iso view.

Plus tiny checked-in binary and ASCII STL files (bytes may be generated by a fixture-writer script and committed) for parser tests: valid binary, valid ASCII, truncated binary (throws), garbage (throws).

**Golden tests.** For (fixture × view) combinations, commit `Goldens/<name>.json` (Codable `LineDrawing`, full precision) and `Goldens/<name>.svg` (human-diffable artifact; regenerated alongside, not compared). Comparison is **numeric with tolerance** (1e-9 absolute per coordinate) after canonical ordering — never string equality, so macOS and Linux libm differences in the last ulps don't flake. Regeneration path: `RECORD_GOLDENS=1 swift test` rewrites goldens; the test then fails with "goldens recorded" so recording can't silently pass CI.

**Invariant & acceptance tests (must pass; these pin the algorithm):**

1. *Cube, front view:* exactly 4 visible paths, each a straight segment of length 1 ± 1e-9, forming the unit square. With `includeHiddenLines` + suppression on: 0 hidden paths (back edges coincide with front). Suppression off: exactly 4 hidden paths coinciding with the visible square.
2. *Cube, isometric:* 9 visible edges, 3 hidden (the classic iso cube). Hidden ones connect to the far corner.
3. *Cylinder (24 segments), front view:* exactly 2 straight visible silhouette lines at screenX = ±radius (± 1e-6), plus visible top and bottom cap lines. No silhouette-derived path deviates from vertical by more than tolerance.
4. *Two offset boxes, front view:* far box has ≥ 1 hidden path; every hidden path's points lie inside the near box's projected rectangle (grown by ε).
5. *Length conservation:* for every candidate edge, Σ(visible sub-segment lengths) + Σ(hidden sub-segment lengths) = projected edge length ± 2 × bisection tolerance. Implement as a debug hook the test can enable.
6. *Determinism:* serial run vs. parallel run vs. repeated parallel run → identical JSON bytes after encoding.
7. *Bounds tightness:* `bounds` exactly equals the min/max over all emitted points.
8. *Weld:* cube-as-STL-soup (36 vertices) welds to 8 positions, 12 non-manifold-free interior edges… i.e. 18 edges total, 0 boundary, 0 non-manifold; degenerate-triangle soup drops and counts correctly.
9. *PDF media box* (`WireframeGraphicsTests`): for a known drawing with bounds 100×50 model units, `pointsPerModelUnit = 0.7087`, margin 10 → media box = (100×0.7087 + 20) × (50×0.7087 + 20) ± 0.001; PDF data is non-empty and begins with `%PDF`.
10. *Concurrency:* package compiles in Swift 6 language mode with zero warnings (enforced by build settings, not a test).

**Performance smoke (non-binding, tracked):** 100k-triangle procedural mesh (subdivided fixture), any view, end-to-end < 1 s on Apple Silicon. Print the timing; don't fail on it.

---

## 8. Explicit non-goals for v1 — do not build these

Perspective projection · section views/cutting planes · arc/circle fitting on output polylines · Metal depth-buffer occlusion variant · STEP/B-rep anything · mesh repair beyond welding & degenerate-drop · corner-joining path chaining · textures/materials/colors · any UI. List them in the README as "planned / vNext" — several (sections, arc recovery) are designed-for but deferred.

---

## 9. Milestones

Each milestone: implement → `swift test` green → verify C1 (grep core imports) → commit `WireframeKit M<n>: <summary>` → post a short summary + proposed deviations → **stop for review**.

- **M1 — Skeleton & mesh.** Package scaffold, LICENSE (MIT © 2026 Justice Engineering), core types (`Mesh`, `MeshDiagnostics`, errors), welding init, adjacency + normals, `STL.parse` (binary + ASCII), procedural fixtures, STL fixture files, weld/adjacency/parser tests (incl. invariant 8).
- **M2 — Project & classify.** `OrthographicView` (+ named views exactly per §3), `DrawingOptions`, edge classification, projection, and an occlusion-free pipeline that emits *every* candidate edge as visible ("x-ray mode" — internal flag). `LineDrawing`, canonical ordering, `svg()`. First goldens: cube + cylinder + L-bracket in front/top/iso, x-ray mode.
- **M3 — Occlusion.** Projected-triangle BVH, occlusion test, visibility sampling + bisection, visible/hidden sub-segments. Invariants 1–5 pass (minus suppression). Goldens for all fixtures × {front, top, right, isometric}, real HLR this time.
- **M4 — Chaining, suppression, determinism, speed.** Collinear chaining, coincidence suppression, TaskGroup parallelism with index-addressed writes + serial path, invariant 6, performance smoke. Re-record goldens (chaining changes path structure — expected; say so in the summary).
- **M5 — Apple targets.** `WireframeModelIO` (+ macOS tests with tiny .obj fixture; .stl routes through core parser), `WireframeGraphics` (`cgPath`, `pdfData`, invariant 9).
- **M6 — OSS polish.** README (what/why, 10-line usage snippet, embedded golden SVGs, non-goals/roadmap), doc comments on all public API, diagnostics surfaced nicely, GitHub Actions workflow file (macOS + Ubuntu matrix: build + test; Ubuntu proves C1 for real), final public-API audit against §3.

---

## 10. Working agreements

- Tests accompany the milestone that introduces the behavior — a milestone without new tests is incomplete.
- When wild-STL reality and this spec conflict (they will), degrade gracefully, record it in `MeshDiagnostics`, and note it in the milestone summary. Never crash on bad input; throw typed errors on unparseable input.
- Keep internal stage functions small and individually testable; the seven pipeline stages are the intended module boundaries for future work (sections and arc fitting will slot in at 4.6/4.7).
- If a numeric tolerance in this spec proves wrong in practice, tune it, but centralize all tolerances in one internal `Tolerances` struct derived from `DrawingOptions` + model size — no magic numbers scattered through stage code.
