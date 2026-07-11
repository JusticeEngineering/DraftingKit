import Foundation
import Testing
@testable import DraftingCore

@Suite("Determinism (invariant 6) & performance smoke")
struct DeterminismTests {

    private func json(_ drawing: LineDrawing) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(drawing)
    }

    // Invariant 6: serial run vs parallel run vs repeated parallel run →
    // identical JSON bytes after encoding.
    @Test func serialAndParallelRunsAreByteIdentical() async throws {
        let cases: [(String, Mesh, OrthographicView)] = [
            ("lbracket-iso", Fixtures.lBracket(), .isometric),
            ("twoboxes-front", Fixtures.twoOffsetBoxes(), .front),
            ("cylinder-front", Fixtures.cylinder(), .front),
            ("cube-iso", Fixtures.cube(), .isometric),
        ]
        for (name, mesh, view) in cases {
            // Explicit serial path (in an async context the async overload
            // would win overload resolution; this is what sync callers get).
            let serial = runPipeline(mesh: mesh, view: view, options: .init(), mode: .full)
            let parallel1 = await makeLineDrawing(mesh: mesh, view: view)
            let parallel2 = await makeLineDrawing(mesh: mesh, view: view)
            // Hoisted: older swift-testing (Linux CI) rejects throwing calls
            // inside #expect's autoclosure.
            let serialJSON = try json(serial)
            let parallelJSON1 = try json(parallel1)
            let parallelJSON2 = try json(parallel2)
            #expect(serialJSON == parallelJSON1, "\(name): serial vs parallel")
            #expect(parallelJSON1 == parallelJSON2, "\(name): parallel repeatability")
            #expect(!serial.paths.isEmpty, "\(name): sanity — drawing must not be empty")
        }
    }

    @Test func parallelChunkingCoversAllSegmentsExactly() async {
        // A mesh with enough candidate edges to span many chunks: the
        // parallel path must produce the same runs array as the serial one.
        let mesh = Fixtures.cylinder(radius: 1, height: 2, radialSegments: 96)
        let scene = prepareScene(mesh: mesh, view: .isometric, options: .init())!
        let tester = OcclusionTester(mesh: mesh, projected: scene.projected,
                                     tolerances: scene.tolerances)
        let serial = computeRunsSerial(scene: scene, tester: tester)
        let parallel = await computeRunsParallel(scene: scene, tester: tester)
        #expect(serial.count == parallel.count)
        #expect(serial == parallel)
    }

    // Performance smoke (non-binding, tracked): ~100k-triangle mesh,
    // end-to-end < 1 s on Apple Silicon. Prints timings; does not fail on
    // them (SPEC §7).
    @Test(.timeLimit(.minutes(2))) func performanceSmoke100kTriangles() async throws {
        let buildClock = ContinuousClock()
        var mesh: Mesh? = nil
        let buildTime = buildClock.measure {
            mesh = Fixtures.subdividedCube(perSide: 91)  // 12 × 91² = 99,372 triangles
        }
        let subject = try #require(mesh)
        #expect(subject.triangles.count == 99_372)
        #expect(subject.edges.allSatisfy { $0.faces.count == 2 })

        let clock = ContinuousClock()
        var serialDrawing: LineDrawing? = nil
        let serialTime = clock.measure {
            serialDrawing = makeLineDrawing(mesh: subject, view: .isometric)
        }

        let parallelStart = clock.now
        let parallelDrawing = await makeLineDrawing(mesh: subject, view: .isometric)
        let parallelTime = clock.now - parallelStart

        print("[perf] subdividedCube 99,372 triangles, isometric view")
        print("[perf]   fixture build: \(buildTime)")
        print("[perf]   makeLineDrawing serial:   \(serialTime)")
        print("[perf]   makeLineDrawing parallel: \(parallelTime)")

        let serial = try #require(serialDrawing)
        #expect(!serial.paths.isEmpty)
        let serialJSON = try json(serial)
        let parallelJSON = try json(parallelDrawing)
        #expect(serialJSON == parallelJSON, "determinism at scale")
        // The drawing of a subdivided cube must still be the cube's 12 edges
        // (chained back together from their collinear sub-edges).
        #expect(serial.paths.count == 12)
        #expect(serial.paths.filter { $0.kind == .visible }.count == 9)
    }
}
