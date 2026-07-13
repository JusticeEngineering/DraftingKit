import Foundation
import Testing
@testable import DraftingCore

@Suite("Cooperative cancellation")
struct CancellationTests {

    /// Big enough that a mid-flight cancel always lands while the pipeline
    /// is still working, even in optimized builds.
    private static let bigMesh = Fixtures.subdividedCube(perSide: 91)  // 99,372 triangles

    @Test func cancelledBeforeStartThrows() async {
        let task = Task {
            try await makeLineDrawing(mesh: Self.bigMesh, view: .isometric)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled run must throw, never return a drawing")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func cancelledMidFlightThrows() async throws {
        let task = Task {
            try await makeLineDrawing(mesh: Self.bigMesh, view: .isometric)
        }
        // Let the pipeline get well into its work, then pull the plug.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled run must throw, never return a drawing")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func uncancelledThrowingOverloadMatchesSerialExactly() async throws {
        let mesh = Fixtures.twoOffsetBoxes()
        let parallel = try await makeLineDrawing(mesh: mesh, view: .front)
        let serial = runPipeline(mesh: mesh, view: .front, options: .init(), mode: .full)
        #expect(parallel == serial, "cancellation support must not change results")
    }

    @Test func checksAreFreeOfSideEffects() async throws {
        // Two identical uncancelled runs through the cancellable path.
        let a = try await makeLineDrawing(mesh: Self.bigMesh, view: .front)
        let b = try await makeLineDrawing(mesh: Self.bigMesh, view: .front)
        #expect(a == b)
        #expect(!a.paths.isEmpty)
    }
}
