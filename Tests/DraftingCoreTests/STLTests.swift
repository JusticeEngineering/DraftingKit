import Foundation
import Testing
@testable import DraftingCore

@Suite("STL parsing (binary + ASCII, autodetected)")
struct STLTests {

    private func fixtureBytes(_ name: String) throws -> [UInt8] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "stl", subdirectory: "Resources"),
            "missing test resource \(name).stl"
        )
        return [UInt8](try Data(contentsOf: url))
    }

    private func expectUnitCube(_ mesh: Mesh) {
        #expect(mesh.diagnostics.inputTriangleCount == 12)
        #expect(mesh.diagnostics.weldedVertexCount == 8)
        #expect(mesh.diagnostics.degenerateTrianglesDropped == 0)
        #expect(mesh.diagnostics.boundaryEdgeCount == 0)
        #expect(mesh.diagnostics.nonManifoldEdgeCount == 0)
        #expect(mesh.triangles.count == 12)
        #expect(mesh.edges.count == 18)
        #expect(Set(mesh.positions) == Set(Fixtures.cube().positions))
    }

    @Test func parsesBinaryCube() throws {
        let mesh = try STL.parse(fixtureBytes("cube-binary"))
        expectUnitCube(mesh)
    }

    @Test func parsesASCIICube() throws {
        let mesh = try STL.parse(fixtureBytes("cube-ascii"))
        expectUnitCube(mesh)
    }

    @Test func binaryAndASCIIAgreeExactly() throws {
        let binary = try STL.parse(fixtureBytes("cube-binary"))
        let ascii = try STL.parse(fixtureBytes("cube-ascii"))
        // Same triangle order in both fixture files → identical welded mesh.
        #expect(binary.positions == ascii.positions)
        #expect(binary.triangles == ascii.triangles)
    }

    @Test func binaryWithSolidHeaderParsesAsBinary() throws {
        // Wild binary files sometimes start with "solid" — the exact size
        // match must win over the ASCII heuristic.
        var bytes = try fixtureBytes("cube-binary")
        bytes.replaceSubrange(0..<10, with: Array("solid junk".utf8))
        let mesh = try STL.parse(bytes)
        expectUnitCube(mesh)
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
        let mesh = try STL.parse(Array(text.utf8))
        #expect(mesh.triangles.count == 2)
        #expect(mesh.diagnostics.inputTriangleCount == 2)
        #expect(mesh.positions.contains(SIMD3(-0.25, 0, 1)))
        #expect(mesh.diagnostics.boundaryEdgeCount == 6)
    }

    // MARK: Errors

    @Test func truncatedBinaryThrows() throws {
        let bytes = try fixtureBytes("truncated-binary")
        #expect(throws: STLError.truncated) {
            _ = try STL.parse(bytes)
        }
    }

    @Test func garbageThrows() throws {
        let bytes = try fixtureBytes("garbage")
        #expect(throws: STLError.truncated) {
            _ = try STL.parse(bytes)
        }
    }

    @Test func emptyInputThrows() {
        #expect(throws: STLError.empty) {
            _ = try STL.parse([])
        }
    }

    @Test func binaryWithZeroTrianglesThrowsEmpty() {
        var header = [UInt8](repeating: 0, count: 84)
        header.replaceSubrange(0..<6, with: Array("binary".utf8))
        #expect(throws: STLError.empty) {
            _ = try STL.parse(header)
        }
    }

    @Test func asciiWithNoFacetsThrowsEmpty() {
        #expect(throws: STLError.empty) {
            _ = try STL.parse(Array("solid nothing\nendsolid nothing\n".utf8))
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
        #expect(throws: STLError.malformedASCII(line: 5)) {
            _ = try STL.parse(Array(text.utf8))
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
        #expect(throws: STLError.malformedASCII(line: 7)) {
            _ = try STL.parse(Array(text.utf8))
        }
    }

    @Test func parseIsDeterministic() throws {
        let bytes = try fixtureBytes("cube-binary")
        let first = try STL.parse(bytes)
        let second = try STL.parse(bytes)
        #expect(first.positions == second.positions)
        #expect(first.triangles == second.triangles)
        #expect(first.edges == second.edges)
        #expect(first.diagnostics == second.diagnostics)
    }
}
