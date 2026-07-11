import Foundation
import Testing
@testable import DraftingCore

// Golden files pin (fixture × view) drawings. JSON is the compared artifact
// (numeric, tolerance 1e-9 per coordinate, after canonical ordering — never
// string equality, so libm last-ulp differences between platforms can't
// flake). The SVG alongside is a human-diffable companion, regenerated with
// the JSON but not compared.
//
// Regenerate: RECORD_GOLDENS=1 swift test
// (recording deliberately fails the run so it can't silently pass CI)

@Suite("Golden drawings (hidden-line removal)")
struct GoldenTests {

    static let fixtures = ["cube", "cylinder", "lbracket", "twoboxes"]
    static let views = ["front", "top", "right", "iso"]
    static let names = fixtures.flatMap { fixture in
        views.map { "\(fixture)-\($0)" }
    }

    static func drawing(for name: String) -> LineDrawing {
        let mesh: Mesh
        switch name.split(separator: "-")[0] {
        case "cube": mesh = Fixtures.cube()
        case "cylinder": mesh = Fixtures.cylinder()
        case "twoboxes": mesh = Fixtures.twoOffsetBoxes()
        default: mesh = Fixtures.lBracket()
        }
        let view: OrthographicView
        switch name.split(separator: "-")[1] {
        case "front": view = .front
        case "top": view = .top
        case "right": view = .right
        default: view = .isometric
        }
        return makeLineDrawing(mesh: mesh, view: view)
    }

    @Test(arguments: names)
    func matchesGolden(_ name: String) throws {
        let drawing = Self.drawing(for: name)

        if ProcessInfo.processInfo.environment["RECORD_GOLDENS"] == "1" {
            try Self.record(name: name, drawing: drawing)
            Issue.record("golden \(name) recorded — rerun without RECORD_GOLDENS")
            return
        }

        let golden = try Self.load(name)
        expectDrawingsMatch(drawing, golden, name: name)
    }

    // MARK: Machinery

    /// The Goldens directory in the SOURCE tree (recording target).
    private static var sourceGoldensDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Goldens")
    }

    private static func record(name: String, drawing: LineDrawing) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let dir = sourceGoldensDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(drawing).write(to: dir.appendingPathComponent("\(name).json"))
        try Data(drawing.svg().utf8).write(to: dir.appendingPathComponent("\(name).svg"))
    }

    private static func load(_ name: String) throws -> LineDrawing {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Goldens"),
            "missing golden \(name).json — record with RECORD_GOLDENS=1 swift test"
        )
        return try JSONDecoder().decode(LineDrawing.self, from: Data(contentsOf: url))
    }
}

/// Numeric golden comparison: identical structure, coordinates within
/// `tolerance` absolutely, after canonical ordering.
func expectDrawingsMatch(_ actual: LineDrawing,
                         _ expected: LineDrawing,
                         tolerance: Double = 1e-9,
                         name: String = "drawing") {
    #expect(actual.paths.count == expected.paths.count, "\(name): path count")
    for (index, (a, e)) in zip(actual.paths, expected.paths).enumerated() {
        #expect(a.kind == e.kind, "\(name): path \(index) kind")
        #expect(a.points.count == e.points.count, "\(name): path \(index) point count")
        for (pa, pe) in zip(a.points, e.points) {
            let close = abs(pa.x - pe.x) <= tolerance && abs(pa.y - pe.y) <= tolerance
            #expect(close, "\(name): path \(index) point \(pa) vs \(pe)")
            if !close { break }
        }
    }
    #expect(abs(actual.bounds.min.x - expected.bounds.min.x) <= tolerance
        && abs(actual.bounds.min.y - expected.bounds.min.y) <= tolerance
        && abs(actual.bounds.max.x - expected.bounds.max.x) <= tolerance
        && abs(actual.bounds.max.y - expected.bounds.max.y) <= tolerance,
        "\(name): bounds")
}
