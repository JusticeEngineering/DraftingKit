import Foundation
import Testing
@testable import WireframeCore

@Suite("STL parsing (binary + ASCII, autodetected)")
struct STLTests {

    private func fixtureBytes(_ name: String) throws -> [UInt8] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "stl", subdirectory: "Resources"),
            "missing test resource \(name).stl"
        )
        return [UInt8](try Data(contentsOf: url))
    }

    private func expectUnitCube(_ mesh: Mesh, _ diag: MeshDiagnostics) {
        #expect(diag.inputTriangleCount == 12)
        #expect(diag.weldedVertexCount == 8)
        #expect(diag.degenerateTrianglesDropped == 0)
        #expect(diag.boundaryEdgeCount == 0)
        #expect(diag.nonManifoldEdgeCount == 0)
        #expect(mesh.triangles.count == 12)
        #expect(mesh.edges.count == 18)
        #expect(Set(mesh.positions) == Set(Fixtures.cube().positions))
    }

    @Test func parsesBinaryCube() throws {
        var diag = MeshDiagnostics()
        let mesh = try STL.parse(fixtureBytes("cube-binary"), diagnostics: &diag)
        expectUnitCube(mesh, diag)
    }

    @Test func parsesASCIICube() throws {
        var diag = MeshDiagnostics()
        let mesh = try STL.parse(fixtureBytes("cube-ascii"), diagnostics: &diag)
        expectUnitCube(mesh, diag)
    }

    @Test func binaryAndASCIIAgreeExactly() throws {
        var d1 = MeshDiagnostics()
        var d2 = MeshDiagnostics()
        let binary = try STL.parse(fixtureBytes("cube-binary"), diagnostics: &d1)
        let ascii = try STL.parse(fixtureBytes("cube-ascii"), diagnostics: &d2)
        // Same triangle order in both fixture files → identical welded mesh.
        #expect(binary.positions == ascii.positions)
        #expect(binary.triangles == ascii.triangles)
    }

    @Test func binaryWithSolidHeaderParsesAsBinary() throws {
        // Wild binary files sometimes start with "solid" — the exact size
        // match must win over the ASCII heuristic.
        var bytes = try fixtureBytes("cube-binary")
        bytes.replaceSubrange(0..<10, with: Array("solid junk".utf8))
        var diag = MeshDiagnostics()
        let mesh = try STL.parse(bytes, diagnostics: &diag)
        expectUnitCube(mesh, diag)
    }

    @Test func asciiToleratesMessyButValidInput() throws {
        let text = """
        SOLID Mixed_Case  \r
          FACET NORMAL 0 0 -1
            OUTER LOOP
              VERTEX 0.0 0e0 0
              VERTEX 1e0 1.0 0
              VERTEX 1.0 0.0 -0.0
            ENDLOOP
          ENDFACET

          facet normal 0 0 1
            outer loop
              vertex -2.5e-1 0 1
              vertex 1 0 1
              vertex 1 1 1
            endloop
          endfacet
        """
        var diag = MeshDiagnostics()
        let mesh = try STL.parse(Array(text.utf8), diagnostics: &diag)
        #expect(mesh.triangles.count == 2)
        #expect(diag.inputTriangleCount == 2)
        #expect(mesh.positions.contains(SIMD3(-0.25, 0, 1)))
        #expect(diag.boundaryEdgeCount == 6)
    }

    // MARK: Errors

    @Test func truncatedBinaryThrows() throws {
        let bytes = try fixtureBytes("truncated-binary")
        var diag = MeshDiagnostics()
        #expect(throws: STLError.truncated) {
            _ = try STL.parse(bytes, diagnostics: &diag)
        }
    }

    @Test func garbageThrows() throws {
        let bytes = try fixtureBytes("garbage")
        var diag = MeshDiagnostics()
        #expect(throws: STLError.truncated) {
            _ = try STL.parse(bytes, diagnostics: &diag)
        }
    }

    @Test func emptyInputThrows() {
        var diag = MeshDiagnostics()
        #expect(throws: STLError.empty) {
            _ = try STL.parse([], diagnostics: &diag)
        }
    }

    @Test func binaryWithZeroTrianglesThrowsEmpty() {
        var header = [UInt8](repeating: 0, count: 84)
        header.replaceSubrange(0..<6, with: Array("binary".utf8))
        var diag = MeshDiagnostics()
        #expect(throws: STLError.empty) {
            _ = try STL.parse(header, diagnostics: &diag)
        }
    }

    @Test func asciiWithNoFacetsThrowsEmpty() {
        var diag = MeshDiagnostics()
        #expect(throws: STLError.empty) {
            _ = try STL.parse(Array("solid nothing\nendsolid nothing\n".utf8), diagnostics: &diag)
        }
    }

    @Test func malformedASCIIReportsLineNumber() {
        let text = """
        solid bad
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 1 0 zero
              vertex 0 1 0
            endloop
          endfacet
        endsolid bad
        """
        var diag = MeshDiagnostics()
        #expect(throws: STLError.malformedASCII(line: 5)) {
            _ = try STL.parse(Array(text.utf8), diagnostics: &diag)
        }
    }

    @Test func asciiMissingVertexThrows() {
        let text = """
        solid bad
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 1 0 0
            endloop
          endfacet
        endsolid bad
        """
        var diag = MeshDiagnostics()
        #expect(throws: STLError.malformedASCII(line: 7)) {
            _ = try STL.parse(Array(text.utf8), diagnostics: &diag)
        }
    }

    @Test func parseIsDeterministic() throws {
        let bytes = try fixtureBytes("cube-binary")
        var d1 = MeshDiagnostics()
        var d2 = MeshDiagnostics()
        let first = try STL.parse(bytes, diagnostics: &d1)
        let second = try STL.parse(bytes, diagnostics: &d2)
        #expect(first.positions == second.positions)
        #expect(first.triangles == second.triangles)
        #expect(first.edges == second.edges)
        #expect(d1 == d2)
    }
}
