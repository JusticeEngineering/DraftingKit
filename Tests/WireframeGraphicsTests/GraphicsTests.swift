#if canImport(CoreGraphics)

import CoreGraphics
import Foundation
import Testing
import WireframeCore
@testable import WireframeGraphics

@Suite("CGPath & PDF output")
struct GraphicsTests {

    private func path(_ points: [(Double, Double)],
                      _ kind: LineDrawing.Kind) -> LineDrawing.Path {
        LineDrawing.Path(points: points.map { SIMD2($0.0, $0.1) }, kind: kind)
    }

    // Invariant 9: bounds 100×50 model units, pointsPerModelUnit = 0.7087,
    // margin 10 → media box (100×0.7087 + 20) × (50×0.7087 + 20) ± 0.001;
    // data non-empty and begins with %PDF.
    @Test func pdfMediaBoxArithmetic() throws {
        let drawing = LineDrawing(
            paths: [path([(0, 0), (100, 50)], .visible),
                    path([(0, 50), (100, 0)], .hidden)],
            bounds: Rect2D(min: SIMD2(0, 0), max: SIMD2(100, 50))
        )
        #expect(drawing.bounds == Rect2D(min: SIMD2(0, 0), max: SIMD2(100, 50)))

        var style = PDFStyle(pointsPerModelUnit: 0.7087)
        style.margin = 10
        let data = drawing.pdfData(style: style)

        #expect(!data.isEmpty)
        #expect(data.prefix(4).elementsEqual("%PDF".utf8))

        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(document.numberOfPages == 1)
        let page = try #require(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        #expect(abs(box.width - (100 * 0.7087 + 20)) <= 0.001)
        #expect(abs(box.height - (50 * 0.7087 + 20)) <= 0.001)
        #expect(box.origin == .zero)
    }

    @Test func mediaBoxRespectsNonZeroBoundsOrigin() throws {
        // Geometry away from the origin: the media box depends only on the
        // bounds SIZE; bounds.min maps to (margin, margin).
        let drawing = LineDrawing(
            paths: [path([(-30, 5), (70, 55)], .visible)],
            bounds: Rect2D(min: SIMD2(-30, 5), max: SIMD2(70, 55))
        )
        var style = PDFStyle(pointsPerModelUnit: 0.5)
        style.margin = 4
        let data = drawing.pdfData(style: style)
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let box = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(abs(box.width - (100 * 0.5 + 8)) <= 0.001)
        #expect(abs(box.height - (50 * 0.5 + 8)) <= 0.001)
    }

    @Test func cgPathSeparatesKindsAndPreservesGeometry() {
        let drawing = LineDrawing(
            paths: [path([(0, 0), (10, 0)], .visible),
                    path([(0, 5), (10, 5), (10, 8)], .hidden)],
            bounds: Rect2D(min: SIMD2(0, 0), max: SIMD2(10, 8))
        )
        let visible = drawing.cgPath(for: .visible)
        let hidden = drawing.cgPath(for: .hidden)

        #expect(visible.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 0))
        #expect(hidden.boundingBoxOfPath == CGRect(x: 0, y: 5, width: 10, height: 3))

        // Model space is y-up and cgPath does NOT flip: the hidden path's
        // top-most point stays at y = 8.
        #expect(hidden.boundingBoxOfPath.maxY == 8)

        let empty = LineDrawing(paths: [], bounds: Rect2D(min: .zero, max: .zero))
            .cgPath(for: .visible)
        #expect(empty.isEmpty)
    }

    @Test func realDrawingProducesParseablePDF() {
        // End-to-end: cube iso through the real pipeline → PDF with both
        // stroke kinds, parseable by CGPDFDocument.
        var diag = MeshDiagnostics()
        let mesh = Mesh(
            weldingSoup: [
                (SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)),
                (SIMD3(0, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)),
            ],
            tolerance: 1e-9,
            diagnostics: &diag
        )
        let drawing = makeLineDrawing(mesh: mesh, view: .top)
        let data = drawing.pdfData(style: PDFStyle(pointsPerModelUnit: 72))
        #expect(!data.isEmpty)
        #expect(CGPDFDocument(CGDataProvider(data: data as CFData)!) != nil)
    }

    @Test func emptyDrawingStillProducesValidPDF() {
        let data = LineDrawing(paths: [], bounds: Rect2D(min: .zero, max: .zero))
            .pdfData(style: PDFStyle(pointsPerModelUnit: 1))
        #expect(data.prefix(4).elementsEqual("%PDF".utf8))
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)
        #expect(document?.numberOfPages == 1)
    }
}

#endif
