// Internal vector helpers over stdlib SIMD types.
//
// DraftingCore imports nothing beyond the Swift standard library (constraint
// C1), so the handful of geometric primitives usually taken from the `simd`
// module live here instead.

@inline(__always)
func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    (a * b).sum()
}

@inline(__always)
func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
}

@inline(__always)
func lengthSquared(_ v: SIMD3<Double>) -> Double {
    dot(v, v)
}

@inline(__always)
func length(_ v: SIMD3<Double>) -> Double {
    lengthSquared(v).squareRoot()
}

/// Returns the unit vector, or .zero when `v` has zero length.
@inline(__always)
func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
    let len = length(v)
    return len > 0 ? v / len : .zero
}

@inline(__always)
func distanceSquared(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    lengthSquared(a - b)
}

@inline(__always)
func isFinite(_ v: SIMD3<Double>) -> Bool {
    v.x.isFinite && v.y.isFinite && v.z.isFinite
}

// MARK: Rounding without libm

// Swift's FloatingPoint.rounded(_:) lowers to libm symbols (floor/ceil/...)
// on Linux, which DraftingCore deliberately doesn't link (constraint C1).
// These use only division and integer conversion (hardware instructions).

/// floor(value / cellSize) as a grid index, clamped to Int64, 0 for NaN.
@inline(__always)
func gridCell(_ value: Double, _ cellSize: Double) -> Int64 {
    let q = value / cellSize
    guard q.isFinite else { return 0 }
    if q >= 9.2e18 { return Int64.max }
    if q <= -9.2e18 { return Int64.min }
    var cell = Int64(q)                             // truncates toward zero
    if q < 0 && Double(cell) != q { cell -= 1 }     // -> floor
    return cell
}

/// ceil(value) as Int for non-negative finite input; 0 otherwise.
@inline(__always)
func ceilToInt(_ value: Double) -> Int {
    guard value.isFinite, value > 0 else { return 0 }
    if value >= 9.2e18 { return Int.max }
    let truncated = Int(value)
    return Double(truncated) == value ? truncated : truncated + 1
}

// MARK: 2D variants (projection stages, M2+)

@inline(__always)
func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    (a * b).sum()
}

/// 2D cross product (z component of the 3D cross of the embedded vectors).
@inline(__always)
func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    a.x * b.y - a.y * b.x
}

@inline(__always)
func lengthSquared(_ v: SIMD2<Double>) -> Double {
    dot(v, v)
}

@inline(__always)
func length(_ v: SIMD2<Double>) -> Double {
    lengthSquared(v).squareRoot()
}
