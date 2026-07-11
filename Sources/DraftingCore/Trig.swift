// Minimal degree-domain trig, stdlib-only (constraint C1: no Foundation/libm).
//
// Folding is done in DEGREES, where the fold points (45/90/180/360) are
// exactly representable, so accuracy reduces to polynomial accuracy on
// [0°, 45°] — Taylor there is accurate to ~1 ulp. Pure IEEE arithmetic also
// makes results bit-identical across platforms, unlike libm (constraint C3).

/// cos of an angle given in degrees. Absolute error < 1e-15 for finite input.
func cosDegrees(_ degrees: Double) -> Double {
    guard degrees.isFinite else { return .nan }
    var d = degrees.magnitude.truncatingRemainder(dividingBy: 360)  // cos(-x) = cos(x)
    if d > 180 { d = 360 - d }                                      // cos(360-x) = cos(x)
    var sign = 1.0
    if d > 90 {
        d = 180 - d                                                 // cos(180-x) = -cos(x)
        sign = -1
    }
    // Fold at 45° so the polynomial argument stays ≤ π/4.
    if d <= 45 {
        return sign * cosPolynomial(d * (Double.pi / 180))
    } else {
        return sign * sinPolynomial((90 - d) * (Double.pi / 180))   // cos(x) = sin(90-x)
    }
}

/// sin of an angle given in degrees. Absolute error < 1e-15 for finite input.
func sinDegrees(_ degrees: Double) -> Double {
    guard degrees.isFinite else { return .nan }
    return cosDegrees(90 - degrees)                                 // sin(x) = cos(90-x)
}

/// Taylor cos on [0, π/4], Horner in x². Truncation < 1e-15 at π/4.
private func cosPolynomial(_ x: Double) -> Double {
    let x2 = x * x
    var acc = -1.0 / 87_178_291_200          // -1/14!
    acc = acc * x2 + 1.0 / 479_001_600       // +1/12!
    acc = acc * x2 - 1.0 / 3_628_800         // -1/10!
    acc = acc * x2 + 1.0 / 40_320            // +1/8!
    acc = acc * x2 - 1.0 / 720               // -1/6!
    acc = acc * x2 + 1.0 / 24                // +1/4!
    acc = acc * x2 - 1.0 / 2                 // -1/2!
    return acc * x2 + 1
}

/// Taylor sin on [0, π/4], Horner in x². Truncation < 1e-16 at π/4.
private func sinPolynomial(_ x: Double) -> Double {
    let x2 = x * x
    var acc = -1.0 / 1_307_674_368_000       // -1/15!
    acc = acc * x2 + 1.0 / 6_227_020_800     // +1/13!
    acc = acc * x2 - 1.0 / 39_916_800        // -1/11!
    acc = acc * x2 + 1.0 / 362_880           // +1/9!
    acc = acc * x2 - 1.0 / 5_040             // -1/7!
    acc = acc * x2 + 1.0 / 120               // +1/5!
    acc = acc * x2 - 1.0 / 6                 // -1/3!
    return (acc * x2 + 1) * x
}
