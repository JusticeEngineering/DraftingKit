# Changelog

## 0.2.0 — 2026-07-13

API-shaping release: source-breaking cleanups done deliberately before 1.0.
CI-verified on macOS and Ubuntu.

### Breaking

- **The async `makeLineDrawing` overload now throws.** Cancelling the
  surrounding task makes it throw `CancellationError` within milliseconds
  (checked between pipeline phases and every 256 edges during sampling).
  It never returns a partial drawing. The synchronous overload is unchanged.
- **Diagnostics moved onto `Mesh`.** The `diagnostics: inout MeshDiagnostics`
  parameter is gone from `STL.parse`, `Mesh(weldingSoup:tolerance:)`, and
  `MeshImport.mesh(contentsOf:)`; read `mesh.diagnostics` instead. The
  validating `Mesh` initializer now populates diagnostics too.
- **`svg()` takes an `SVGStyle`** (`svg(style:)`) instead of six loose
  parameters. Defaults produce byte-identical output to 0.1.0's defaults.
- **`Mesh.boundingBox` returns `Box3D`** (with `.size` and `.diagonal`)
  instead of a `(min:max:)` tuple. `.min`/`.max` member access is unchanged.

### Added

- `OrthographicView(azimuthDegrees:elevationDegrees:)` — orbit-style view
  construction for Z-up models, computed with the library's deterministic
  trig (bit-identical across platforms).
- `Box3D`, `SVGStyle` types.

### Migrating from 0.1.0

```swift
// Parsing + diagnostics
var diag = MeshDiagnostics()                          // ← delete
let mesh = try STL.parse(bytes, diagnostics: &diag)   // 0.1.0
let mesh = try STL.parse(bytes)                       // 0.2.0
diag.boundaryEdgeCount                                // 0.1.0
mesh.diagnostics.boundaryEdgeCount                    // 0.2.0

// Same change for:
Mesh(weldingSoup: soup, tolerance: t)                 // no diagnostics: param
MeshImport.mesh(contentsOf: url)                      // no diagnostics: param

// Parallel drawing (cancellation-aware)
let d = await makeLineDrawing(mesh: m, view: v)       // 0.1.0
let d = try await makeLineDrawing(mesh: m, view: v)   // 0.2.0 — catch CancellationError

// SVG styling
drawing.svg(strokeWidth: 2, margin: 4)                       // 0.1.0
drawing.svg(style: SVGStyle(strokeWidth: 2, margin: 4))      // 0.2.0

// Bounds
let (mn, mx) = mesh.boundingBox                       // 0.1.0 (tuple)
let box = mesh.boundingBox                            // 0.2.0: box.min/.max/.size/.diagonal
```

## 0.1.0 — 2026-07-11

First tagged pre-release: STL/OBJ/USDZ ingest, per-view edge classification,
sampling-based hidden-line removal over a BVH, collinear chaining and
coincidence suppression, deterministic serial/parallel execution, SVG and
scale-accurate PDF output, macOS + Ubuntu CI.
