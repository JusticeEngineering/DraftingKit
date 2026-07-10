// STL parsing (binary + ASCII, autodetected), pure core so Linux CI can run
// the whole pipeline end-to-end. File I/O is the caller's job: bytes in,
// welded Mesh out.

public enum STLError: Error, Sendable, Equatable {
    case truncated
    case malformedASCII(line: Int)
    case empty
}

public enum STL {
    /// Parses binary or ASCII STL (autodetected) and welds it.
    /// `weldToleranceFraction` is relative to the soup's bounding diagonal.
    public static func parse(_ bytes: [UInt8],
                             weldToleranceFraction: Double = 1e-6,
                             diagnostics: inout MeshDiagnostics) throws -> Mesh {
        guard !bytes.isEmpty else { throw STLError.empty }

        let soup: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]
        if let declared = binaryTriangleCount(bytes), 84 + 50 * declared == bytes.count {
            // Exact binary size match — unambiguous, even if the 80-byte
            // header happens to start with "solid".
            soup = parseBinary(bytes, triangleCount: declared)
        } else if startsWithSolid(bytes) {
            soup = try parseASCII(bytes)
        } else if let declared = binaryTriangleCount(bytes) {
            if 84 + 50 * declared <= bytes.count {
                // Trailing junk after the last triangle: tolerate it.
                soup = parseBinary(bytes, triangleCount: declared)
            } else {
                throw STLError.truncated
            }
        } else {
            // Shorter than a binary header and not ASCII.
            throw STLError.truncated
        }

        guard !soup.isEmpty else { throw STLError.empty }

        // Soup bounding diagonal over finite vertices only (non-finite
        // triangles are dropped during welding and must not skew tolerance).
        var bounds: (mn: SIMD3<Double>, mx: SIMD3<Double>)? = nil
        for (a, b, c) in soup {
            for p in [a, b, c] where isFinite(p) {
                if let current = bounds {
                    bounds = (pointwiseMin(current.mn, p), pointwiseMax(current.mx, p))
                } else {
                    bounds = (p, p)
                }
            }
        }
        let diagonal = bounds.map { length($0.mx - $0.mn) } ?? 0
        // Degenerate extent (single point / all non-finite): fall back to the
        // fraction itself so welding still merges exact duplicates.
        let tolerance = diagonal > 0 ? weldToleranceFraction * diagonal : weldToleranceFraction
        return Mesh(weldingSoup: soup, tolerance: tolerance, diagnostics: &diagnostics)
    }

    // MARK: Binary

    /// Declared triangle count if `bytes` is at least header-sized, else nil.
    private static func binaryTriangleCount(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 84 else { return nil }
        let n = UInt32(bytes[80])
            | UInt32(bytes[81]) << 8
            | UInt32(bytes[82]) << 16
            | UInt32(bytes[83]) << 24
        return Int(n)
    }

    private static func float32(_ bytes: [UInt8], at offset: Int) -> Double {
        let raw = UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        return Double(Float(bitPattern: raw))
    }

    private static func parseBinary(_ bytes: [UInt8], triangleCount: Int)
        -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]
    {
        var soup: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        soup.reserveCapacity(triangleCount)
        var offset = 84
        for _ in 0..<triangleCount {
            // 12 bytes facet normal (ignored; recomputed from geometry),
            // 3 × 12 bytes vertices, 2 bytes attribute byte count (ignored).
            var vertices = [SIMD3<Double>]()
            vertices.reserveCapacity(3)
            for v in 0..<3 {
                let base = offset + 12 + v * 12
                vertices.append(SIMD3(
                    float32(bytes, at: base),
                    float32(bytes, at: base + 4),
                    float32(bytes, at: base + 8)
                ))
            }
            soup.append((vertices[0], vertices[1], vertices[2]))
            offset += 50
        }
        return soup
    }

    // MARK: ASCII

    private static func startsWithSolid(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D {
            i += 1
        }
        let keyword: [UInt8] = [0x73, 0x6F, 0x6C, 0x69, 0x64] // "solid"
        guard i + keyword.count <= bytes.count else { return false }
        for (j, k) in keyword.enumerated() where bytes[i + j] | 0x20 != k {
            return false
        }
        return true
    }

    private static func parseASCII(_ bytes: [UInt8]) throws
        -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]
    {
        let text = String(decoding: bytes, as: UTF8.self)
        var soup: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []

        // Facet state machine. Lenient where wild files are sloppy (blank
        // lines, missing endsolid, multiple solids, keyword case), strict
        // about structure inside a facet.
        var pendingVertices: [SIMD3<Double>] = []
        var insideFacet = false
        var lineNumber = 0

        // Note: "\r\n" is a single Character (grapheme cluster) in Swift, so
        // it must be listed as its own separator — splitting on "\n" alone
        // would leave CRLF-terminated lines glued together.
        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        ) {
            lineNumber += 1
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = tokens.first?.lowercased() else { continue }

            switch keyword {
            case "solid", "endsolid":
                if insideFacet { throw STLError.malformedASCII(line: lineNumber) }
            case "facet":
                if insideFacet { throw STLError.malformedASCII(line: lineNumber) }
                insideFacet = true
                pendingVertices.removeAll(keepingCapacity: true)
            case "outer", "endloop":
                if !insideFacet { throw STLError.malformedASCII(line: lineNumber) }
            case "vertex":
                guard insideFacet, pendingVertices.count < 3, tokens.count >= 4,
                      let x = Double(tokens[1]), let y = Double(tokens[2]), let z = Double(tokens[3])
                else { throw STLError.malformedASCII(line: lineNumber) }
                pendingVertices.append(SIMD3(x, y, z))
            case "endfacet":
                guard insideFacet, pendingVertices.count == 3 else {
                    throw STLError.malformedASCII(line: lineNumber)
                }
                soup.append((pendingVertices[0], pendingVertices[1], pendingVertices[2]))
                insideFacet = false
            default:
                throw STLError.malformedASCII(line: lineNumber)
            }
        }

        if insideFacet {
            throw STLError.malformedASCII(line: lineNumber)
        }
        return soup
    }
}
