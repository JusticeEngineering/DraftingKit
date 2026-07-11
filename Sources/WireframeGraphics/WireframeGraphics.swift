// WireframeGraphics — CoreGraphics output: CGPath per kind and single-page
// vector PDF Data. CoreGraphics only, no AppKit — the host app owns NSImage
// (`NSImage(data: pdfData)` draws vector-sharp at any zoom).
//
// The media-box arithmetic is load-bearing for the app's scale-accurate
// placement (SPEC §6): mediaBox = bounds.size × pointsPerModelUnit + 2×margin,
// geometry translated so bounds.min maps to (margin, margin).

#if canImport(CoreGraphics)

import CoreGraphics
import Foundation
import WireframeCore

public struct PDFStyle: Sendable {
    /// PDF points per model unit. The app computes this from user scale +
    /// units, e.g. mm at 1:4 → (72 / 25.4) / 4 ≈ 0.7087.
    public var pointsPerModelUnit: Double
    /// Stroke widths in PDF points — on paper, independent of model scale.
    public var visibleLineWidth: Double = 1.0
    public var hiddenLineWidth: Double = 0.75
    /// Dash pattern for hidden lines, in PDF points.
    public var hiddenDashPattern: [Double] = [4, 3]
    /// Margin added on all sides, in PDF points.
    public var margin: Double = 0

    public init(pointsPerModelUnit: Double) {
        self.pointsPerModelUnit = pointsPerModelUnit
    }
}

public extension LineDrawing {
    /// One CGPath containing every path of `kind`, in model-space
    /// coordinates, y-up. PDF is y-up too, so unlike SVG there is NO flip.
    func cgPath(for kind: Kind) -> CGPath {
        let path = CGMutablePath()
        for p in paths where p.kind == kind {
            guard let first = p.points.first else { continue }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in p.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
        }
        return path
    }

    /// Single-page vector PDF.
    /// MediaBox = bounds.size × pointsPerModelUnit + 2 × margin; geometry is
    /// translated so bounds.min maps to (margin, margin). Hidden lines are
    /// stroked first (dashed, thinner), visible lines over them.
    func pdfData(style: PDFStyle) -> Data {
        let scale = style.pointsPerModelUnit
        // Degenerate drawings (empty, or zero-extent with no margin) still
        // produce a valid PDF with a minimal 1×1pt page.
        let width = Swift.max(bounds.size.x * scale + 2 * style.margin, 1)
        let height = Swift.max(bounds.size.y * scale + 2 * style.margin, 1)
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }

        context.beginPDFPage(nil)
        context.saveGState()
        // (margin, margin) ← bounds.min, then model units → points.
        context.translateBy(x: CGFloat(style.margin), y: CGFloat(style.margin))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: CGFloat(-bounds.min.x), y: CGFloat(-bounds.min.y))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Stroke widths and dash lengths are specified in PDF points; the
        // CTM is scaled by pointsPerModelUnit, so divide it back out.
        let hidden = cgPath(for: .hidden)
        if !hidden.isEmpty {
            context.setLineWidth(CGFloat(style.hiddenLineWidth / scale))
            context.setLineDash(phase: 0,
                                lengths: style.hiddenDashPattern.map { CGFloat($0 / scale) })
            context.addPath(hidden)
            context.strokePath()
        }

        let visible = cgPath(for: .visible)
        if !visible.isEmpty {
            context.setLineWidth(CGFloat(style.visibleLineWidth / scale))
            context.setLineDash(phase: 0, lengths: [])
            context.addPath(visible)
            context.strokePath()
        }

        context.restoreGState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

#endif
