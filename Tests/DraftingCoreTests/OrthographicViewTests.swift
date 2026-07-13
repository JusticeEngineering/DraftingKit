import Foundation
import Testing
@testable import DraftingCore

@Suite("Screen basis & named views (SPEC §3 — exact)")
struct OrthographicViewTests {

    // The spec fixes the basis construction; these are the contract tests.
    @Test func basisMatchesSpecFormulas() {
        let view = OrthographicView(forward: SIMD3(-1, 1, -1), up: SIMD3(0, 0, 1))
        let expectedRight = normalize(cross(view.forward, SIMD3(0, 0, 1)))
        let expectedTrueUp = cross(expectedRight, view.forward)
        #expect(view.right == expectedRight)
        #expect(view.trueUp == expectedTrueUp)
        #expect(abs(length(view.forward) - 1) < 1e-15)
        #expect(abs(length(view.right) - 1) < 1e-15)
        #expect(abs(length(view.trueUp) - 1) < 1e-15)
        #expect(abs(dot(view.right, view.forward)) < 1e-15)
        #expect(abs(dot(view.trueUp, view.forward)) < 1e-15)
        #expect(abs(dot(view.right, view.trueUp)) < 1e-15)
    }

    @Test func namedViewDirectionsPerSpec() {
        #expect(OrthographicView.front.forward == SIMD3(0, 1, 0))
        #expect(OrthographicView.back.forward == SIMD3(0, -1, 0))
        #expect(OrthographicView.right.forward == SIMD3(-1, 0, 0))
        #expect(OrthographicView.left.forward == SIMD3(1, 0, 0))
        #expect(OrthographicView.top.forward == SIMD3(0, 0, -1))
        #expect(OrthographicView.bottom.forward == SIMD3(0, 0, 1))
        let iso = OrthographicView.isometric
        let s = 1.0 / 3.0.squareRoot()
        #expect(length(iso.forward - SIMD3(-s, s, -s)) < 1e-15)
        #expect(iso.up == SIMD3(0, 0, 1))
    }

    // Front view: screen x = world x, screen y = world z, depth = world y.
    @Test func frontViewProjection() {
        let p = OrthographicView.front.project(SIMD3(1, 2, 3))
        #expect(p == SIMD3(1, 3, 2))
    }

    @Test func topViewProjection() {
        // Looking down: screen x = world x, screen y = world y, depth = -z
        // (higher points are closer to the viewer ⇒ smaller depth).
        let p = OrthographicView.top.project(SIMD3(1, 2, 3))
        #expect(p == SIMD3(1, 2, -3))
    }

    @Test func rightViewProjection() {
        // Viewer at +X looking -X: screen x = world y, screen y = world z.
        let p = OrthographicView.right.project(SIMD3(1, 2, 3))
        #expect(p == SIMD3(2, 3, -1))
    }

    @Test func smallerDepthIsCloserToViewer() {
        // Front viewer sits at -Y; y = 0 is closer than y = 5.
        let near = OrthographicView.front.project(SIMD3(0, 0, 0))
        let far = OrthographicView.front.project(SIMD3(0, 5, 0))
        #expect(near.z < far.z)
    }

    @Test func initNormalizesInputs() {
        let view = OrthographicView(forward: SIMD3(0, 10, 0), up: SIMD3(0, 0, 7))
        #expect(view.forward == SIMD3(0, 1, 0))
        #expect(view.up == SIMD3(0, 0, 1))
        #expect(view.right == SIMD3(1, 0, 0))
    }

    @Test func degenerateUpFallsBackGracefully() {
        // up parallel to forward: basis must still be orthonormal.
        let view = OrthographicView(forward: SIMD3(0, 0, 1), up: SIMD3(0, 0, -1))
        #expect(abs(length(view.right) - 1) < 1e-15)
        #expect(abs(dot(view.right, view.forward)) < 1e-15)
        #expect(abs(dot(view.trueUp, view.forward)) < 1e-15)

        let zeroUp = OrthographicView(forward: SIMD3(0, 1, 0), up: .zero)
        #expect(abs(length(zeroUp.right) - 1) < 1e-15)
    }

    @Test func orbitInitializerMatchesNamedViews() {
        // The named-view angles under the orbit convention (azimuth from +X
        // around +Z, elevation above the horizon). Degree-domain folds make
        // these bases exactly equal, not just close.
        let cases: [(OrthographicView, OrthographicView)] = [
            (OrthographicView(azimuthDegrees: -90, elevationDegrees: 0), .front),
            (OrthographicView(azimuthDegrees: 90, elevationDegrees: 0), .back),
            (OrthographicView(azimuthDegrees: 0, elevationDegrees: 0), .right),
            (OrthographicView(azimuthDegrees: 180, elevationDegrees: 0), .left),
            (OrthographicView(azimuthDegrees: -90, elevationDegrees: 90), .top),
            (OrthographicView(azimuthDegrees: -90, elevationDegrees: -90), .bottom),
        ]
        for (orbit, named) in cases {
            #expect(length(orbit.forward - named.forward) < 1e-15)
            #expect(length(orbit.right - named.right) < 1e-15)
            #expect(length(orbit.trueUp - named.trueUp) < 1e-15)
        }

        // Arbitrary angles still produce an orthonormal basis.
        let oblique = OrthographicView(azimuthDegrees: -55, elevationDegrees: 35)
        #expect(abs(length(oblique.forward) - 1) < 1e-15)
        #expect(abs(dot(oblique.right, oblique.forward)) < 1e-15)
        #expect(abs(dot(oblique.trueUp, oblique.forward)) < 1e-15)
        #expect(oblique.forward.z < 0, "positive elevation looks down")
    }

    @Test func isometricSeesThreeCubeFaces() {
        // Sanity: the iso viewer is up-front-right, so the cube corner
        // (1, 0, 1) must be strictly closer than the opposite corner (0, 1, 0).
        let iso = OrthographicView.isometric
        let nearCorner = iso.project(SIMD3(1, 0, 1))
        let farCorner = iso.project(SIMD3(0, 1, 0))
        #expect(nearCorner.z < farCorner.z)
    }
}

@Suite("Degree-domain trig (stdlib-only, clean-room)")
struct TrigTests {

    @Test func matchesLibmAcrossFullSweep() {
        var degrees = -720.0
        while degrees <= 720 {
            #expect(abs(cosDegrees(degrees) - Foundation.cos(degrees * .pi / 180)) < 1e-13,
                    "cos(\(degrees)°)")
            #expect(abs(sinDegrees(degrees) - Foundation.sin(degrees * .pi / 180)) < 1e-13,
                    "sin(\(degrees)°)")
            degrees += 0.37  // avoids hitting only "nice" angles
        }
    }

    @Test func exactAtCardinalAngles() {
        #expect(cosDegrees(0) == 1)
        #expect(cosDegrees(90) == 0)
        #expect(cosDegrees(180) == -1)
        #expect(cosDegrees(270) == 0)
        #expect(cosDegrees(360) == 1)
        #expect(sinDegrees(0) == 0)
        #expect(sinDegrees(90) == 1)
    }

    @Test func nonFiniteInputYieldsNaN() {
        #expect(cosDegrees(.infinity).isNaN)
        #expect(cosDegrees(.nan).isNaN)
        #expect(sinDegrees(-.infinity).isNaN)
    }
}
