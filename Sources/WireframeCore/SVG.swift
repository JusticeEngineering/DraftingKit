// SVG rendering — debug artifact, golden-file companion, and a free win for
// OSS users. Not the production output path (that's WireframeGraphics' PDF).

public extension LineDrawing {
    /// Renders the drawing as a standalone SVG string.
    ///
    /// Coordinates are y-flipped for SVG's y-down space; the viewBox is the
    /// drawing bounds plus `margin` on all sides, in model units. Visible
    /// paths are solid strokes, hidden paths dashed. Transparent background.
    func svg(strokeWidth: Double = 1.0,
             hiddenDashPattern: [Double] = [4, 3],
             margin: Double = 2.0) -> String {
        let width = bounds.size.x + 2 * margin
        let height = bounds.size.y + 2 * margin

        var out = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) \(height)">

        """

        for kind in Kind.allCases {
            let kindPaths = paths.filter { $0.kind == kind }
            if kindPaths.isEmpty { continue }
            var attributes = "fill=\"none\" stroke=\"black\" stroke-width=\"\(strokeWidth)\""
            if kind == .hidden {
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
