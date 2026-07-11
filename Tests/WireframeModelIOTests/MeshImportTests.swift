#if canImport(ModelIO)

import Foundation
import Testing
import WireframeCore
@testable import WireframeModelIO

@Suite("ModelIO mesh import")
struct MeshImportTests {

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext,
                                       subdirectory: "Resources"),
                     "missing test resource \(name).\(ext)")
    }

    @Test func importsOBJCube() throws {
        var diag = MeshDiagnostics()
        let mesh = try MeshImport.mesh(contentsOf: fixtureURL("cube", "obj"),
                                       diagnostics: &diag)
        // 6 quad faces → 12 triangles → welds back to the unit cube.
        #expect(mesh.positions.count == 8)
        #expect(mesh.triangles.count == 12)
        #expect(diag.weldedVertexCount == 8)
        #expect(diag.boundaryEdgeCount == 0)
        #expect(diag.nonManifoldEdgeCount == 0)
        #expect(diag.degenerateTrianglesDropped == 0)

        let box = mesh.boundingBox
        #expect(box.min == SIMD3(0, 0, 0))
        #expect(box.max == SIMD3(1, 1, 1))

        // Outward winding survived the import: signed volume = +1.
        var sixVolume = 0.0
        for t in mesh.triangles {
            let p0 = mesh.positions[t.x], p1 = mesh.positions[t.y], p2 = mesh.positions[t.z]
            sixVolume += p0.x * (p1.y * p2.z - p1.z * p2.y)
                - p0.y * (p1.x * p2.z - p1.z * p2.x)
                + p0.z * (p1.x * p2.y - p1.y * p2.x)
        }
        #expect(abs(sixVolume / 6 - 1) < 1e-9)
    }

    @Test func importedOBJDrawsLikeTheProceduralCube() throws {
        var diag = MeshDiagnostics()
        let mesh = try MeshImport.mesh(contentsOf: fixtureURL("cube", "obj"),
                                       diagnostics: &diag)
        let drawing = makeLineDrawing(mesh: mesh, view: .front)
        #expect(drawing.paths.count == 4)
        #expect(drawing.paths.allSatisfy { $0.kind == .visible })
        #expect(drawing.bounds == Rect2D(min: SIMD2(0, 0), max: SIMD2(1, 1)))
    }

    @Test func stlRoutesThroughCoreParser() throws {
        var diag = MeshDiagnostics()
        let mesh = try MeshImport.mesh(contentsOf: fixtureURL("cube-binary", "stl"),
                                       diagnostics: &diag)
        #expect(mesh.positions.count == 8)
        #expect(mesh.triangles.count == 12)
        #expect(diag.inputTriangleCount == 12)
        #expect(diag.weldedVertexCount == 8)
        #expect(diag.boundaryEdgeCount == 0)
        #expect(diag.nonManifoldEdgeCount == 0)
    }

    @Test func stlErrorsSurfaceAsSTLErrors() throws {
        // Core parser errors pass through untranslated — one parser, one
        // behavior.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wireframekit-truncated-\(UUID().uuidString).stl")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var diag = MeshDiagnostics()
        #expect(throws: STLError.truncated) {
            _ = try MeshImport.mesh(contentsOf: url, diagnostics: &diag)
        }
    }

    @Test func missingFileThrowsUnreadable() {
        var diag = MeshDiagnostics()
        let missing = URL(fileURLWithPath: "/nonexistent/wireframekit-\(UUID().uuidString).obj")
        #expect(throws: MeshImportError.unreadableFile) {
            _ = try MeshImport.mesh(contentsOf: missing, diagnostics: &diag)
        }
    }

    @Test func meshlessAssetThrowsNoGeometry() throws {
        // A readable file MDLAsset accepts but finds no meshes in.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wireframekit-empty-\(UUID().uuidString).obj")
        try Data("# just a comment\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var diag = MeshDiagnostics()
        #expect(throws: MeshImportError.noGeometry) {
            _ = try MeshImport.mesh(contentsOf: url, diagnostics: &diag)
        }
    }
}

#endif
