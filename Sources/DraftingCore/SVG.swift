// SVG rendering — debug artifact, golden-file companion, and a free win for
// OSS users. Not the production output path (that's DraftingGraphics' PDF).

/// Styling for `LineDrawing.svg(style:)` — the SVG sibling of `PDFStyle`.
///
/// All lengths (stroke widths, dashes, margin) are in MODEL units, like the
/// SVG's viewBox — scale them with the drawing's size for a consistent
/// on-screen weight (e.g. `strokeWidth = maxDimension / 1000`).
public struct SVGStyle: Sendable {
    /// Visible stroke width, in model units.
    public var strokeWidth: Double
    /// Hidden stroke width; nil means 62.5% of `strokeWidth`.
    public var hiddenStrokeWidth: Double?
    /// Dash pattern for hidden lines, in model units.
    public var hiddenDashPattern: [Double]
    /// Margin added on all sides of the viewBox, in model units.
    public var margin: Double
    /// CSS color of visible strokes.
    public var visibleColor: String
    /// CSS color of hidden strokes.
    public var hiddenColor: String

    /// Creates a style; defaults give solid black visible lines and thinner
    /// dashed gray hidden lines — the usual drafting look.
    public init(strokeWidth: Double = 1.0,
                hiddenStrokeWidth: Double? = nil,
                hiddenDashPattern: [Double] = [4, 3],
                margin: Double = 2.0,
                visibleColor: String = "black",
                hiddenColor: String = "#808080") {
        self.strokeWidth = strokeWidth
        self.hiddenStrokeWidth = hiddenStrokeWidth
        self.hiddenDashPattern = hiddenDashPattern
        self.margin = margin
        self.visibleColor = visibleColor
        self.hiddenColor = hiddenColor
    }
}

public extension LineDrawing {
    /// Renders the drawing as a standalone SVG string.
    ///
    /// Coordinates are y-flipped for SVG's y-down space; the viewBox is the
    /// drawing bounds plus the style's margin on all sides, in model units.
    /// Transparent background.
    func svg(style: SVGStyle = SVGStyle()) -> String {
        let strokeWidth = style.strokeWidth
        let hiddenDashPattern = style.hiddenDashPattern
        let margin = style.margin
        let hiddenStrokeWidth = style.hiddenStrokeWidth
        let visibleColor = style.visibleColor
        let hiddenColor = style.hiddenColor
        let width = bounds.size.x + 2 * margin
        let height = bounds.size.y + 2 * margin

        var out = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)">

        """

        for kind in Kind.allCases {
            let kindPaths = paths.filter { $0.kind == kind }
            if kindPaths.isEmpty { continue }
            let isHidden = kind == .hidden
            let kindWidth = isHidden ? (hiddenStrokeWidth ?? strokeWidth * 0.625) : strokeWidth
            let kindColor = isHidden ? hiddenColor : visibleColor
            var attributes = "fill=\"none\" stroke=\"\(kindColor)\" stroke-width=\"\(kindWidth)\""
            if isHidden {
                let dashes = hiddenDashPattern.map { "\($0)" }.joined(separator: " ")
                attributes += " stroke-dasharray=\"\(dashes)\""
            }
            out += "  <g class=\"\(kind.rawValue)\" \(attributes)>\n"
            for path in kindPaths {
                let points = path.points
                    .map { "\($0.x - bounds.min.x + margin),\(bounds.max.y - $0.y + margin)" }
                    .joined(separator: " ")
                out += "    <polyline points=\"\(points)\"/>\n"
            }
            out += "  </g>\n"
        }

        out += "</svg>\n"
        return out
    }
}
