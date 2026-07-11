// DraftingModelIO — ModelIO-based mesh ingest: .obj / .usdz (and anything
// else MDLAsset can read) → welded DraftingCore.Mesh.
//
// .stl URLs are read as bytes and routed through core's STL.parse — one
// parser, one behavior, testable on Linux (SPEC §5).

#if canImport(ModelIO)

import Foundation
import ModelIO
import DraftingCore

public enum MeshImportError: Error, Sendable, Equatable {
    /// The file doesn't exist or couldn't be read.
    case unreadableFile
    /// The asset loaded but contained no usable triangle geometry.
    case noGeometry
}

public enum MeshImport {
    /// Loads a mesh file, flattens all submeshes to triangles, welds, and
    /// returns the mesh plus diagnostics.
    ///
    /// Positions are converted to Double via ModelIO's float3 conversion;
    /// 8/16/32-bit indices, triangles, triangle strips and quads are all
    /// accepted. Everything is flattened to a triangle soup and welded, so
    /// coincident vertices merge exactly as they do for STL input.
    public static func mesh(contentsOf url: URL,
                            weldToleranceFraction: Double = 1e-6,
                            diagnostics: inout MeshDiagnostics) throws -> Mesh {
        if url.pathExtension.lowercased() == "stl" {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw MeshImportError.unreadableFile
            }
            return try STL.parse([UInt8](data),
                                 weldToleranceFraction: weldToleranceFraction,
                                 diagnostics: &diagnostics)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MeshImportError.unreadableFile
        }

        let asset = MDLAsset(url: url)
        var soup: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for object in asset.childObjects(of: MDLMesh.self) {
            guard let mesh = object as? MDLMesh else { continue }
            appendTriangles(of: mesh, to: &soup)
        }
        guard !soup.isEmpty else { throw MeshImportError.noGeometry }

        var mn = soup[0].0, mx = soup[0].0
        for (a, b, c) in soup {
            for p in [a, b, c] {
                mn = SIMD3(Swift.min(mn.x, p.x), Swift.min(mn.y, p.y), Swift.min(mn.z, p.z))
                mx = SIMD3(Swift.max(mx.x, p.x), Swift.max(mx.y, p.y), Swift.max(mx.z, p.z))
            }
        }
        let size = mx - mn
        let diagonal = (size.x * size.x + size.y * size.y + size.z * size.z).squareRoot()
        let tolerance = diagonal > 0 && diagonal.isFinite
            ? weldToleranceFraction * diagonal
            : weldToleranceFraction
        return Mesh(weldingSoup: soup, tolerance: tolerance, diagnostics: &diagnostics)
    }

    // MARK: MDLMesh extraction

    private static func appendTriangles(of mesh: MDLMesh,
                                        to soup: inout [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]) {
        // vertexAttributeData converts whatever the source format is
        // (float2/3/4, double, packed…) to a contiguous float3 view.
        guard let attribute = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition,
                                                       as: .float3) else { return }
        let base = attribute.dataStart
        let stride = attribute.stride
        let vertexCount = mesh.vertexCount

        func position(_ index: Int) -> SIMD3<Double>? {
            guard index >= 0 && index < vertexCount else { return nil }
            let p = base.advanced(by: index * stride).assumingMemoryBound(to: Float.self)
            return SIMD3(Double(p[0]), Double(p[1]), Double(p[2]))
        }

        guard let submeshes = mesh.submeshes else { return }
        for case let submesh as MDLSubmesh in submeshes {
            let indexBuffer = submesh.indexBuffer(asIndexType: .uInt32)
            let indices = indexBuffer.map().bytes.assumingMemoryBound(to: UInt32.self)
            let indexCount = submesh.indexCount

            func emit(_ i0: Int, _ i1: Int, _ i2: Int) {
                guard let a = position(Int(indices[i0])),
                      let b = position(Int(indices[i1])),
                      let c = position(Int(indices[i2])) else { return }
                soup.append((a, b, c))
            }

            switch submesh.geometryType {
            case .triangles:
                var i = 0
                while i + 2 < indexCount {
                    emit(i, i + 1, i + 2)
                    i += 3
                }
            case .triangleStrips:
                for i in 0..<Swift.max(0, indexCount - 2) {
                    // Alternate winding to keep faces consistently oriented.
                    if i.isMultiple(of: 2) {
                        emit(i, i + 1, i + 2)
                    } else {
                        emit(i + 1, i, i + 2)
                    }
                }
            case .quads:
                var i = 0
                while i + 3 < indexCount {
                    emit(i, i + 1, i + 2)
                    emit(i, i + 2, i + 3)
                    i += 4
                }
            default:
                continue  // lines, points, variable topology: nothing to draw
            }
        }
    }
}

#endif
