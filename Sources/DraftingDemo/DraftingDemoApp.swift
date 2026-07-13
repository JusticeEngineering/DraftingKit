// DraftingDemo — dead-simple manual test harness for DraftingKit.
//
//   swift run -c release DraftingDemo                  (GUI)
//   swift run -c release DraftingDemo bench <file>     (headless timings)
//
// Import an STL/OBJ/USDZ, aim the view with presets or azimuth/elevation
// sliders, and see the hidden-line drawing rendered through the REAL
// production path: makeLineDrawing → pdfData → NSImage. Not part of the
// library API; excluded from non-macOS builds.
//
// Run with -c release for real meshes: debug builds are 10–30× slower.

#if os(macOS)

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DraftingCore
import DraftingGraphics
import DraftingModelIO

@main
enum Entry {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count >= 3, arguments[1] == "bench" {
            await runBenchmark(path: arguments[2])
        } else if arguments.count >= 4, arguments[1] == "hero" {
            // hero <model> <output-dir> [azimuth] [elevation] [creaseAngle]
            await renderHero(path: arguments[2], outputDirectory: arguments[3],
                             azimuth: arguments.count > 4 ? Double(arguments[4]) ?? -55 : -55,
                             elevation: arguments.count > 5 ? Double(arguments[5]) ?? 35 : 35,
                             creaseAngle: arguments.count > 6 ? Double(arguments[6]) ?? 30 : 30)
        } else {
            DraftingDemoApp.main()
        }
    }
}

// MARK: - Hero/readme asset export

/// Headless render: imports a model, draws it from the given orbit angles,
/// and writes hero.png (display bitmap) + hero.svg into the output directory.
private func renderHero(path: String, outputDirectory: String,
                        azimuth: Double, elevation: Double, creaseAngle: Double) async {
    var diagnostics = MeshDiagnostics()
    guard let mesh = try? MeshImport.mesh(contentsOf: URL(fileURLWithPath: path),
                                          diagnostics: &diagnostics) else {
        print("import FAILED: \(path)")
        return
    }
    var parameters = DrawingParameters()
    parameters.azimuthDegrees = azimuth
    parameters.elevationDegrees = elevation
    parameters.creaseAngleDegrees = creaseAngle
    guard let drawing = try? await makeLineDrawing(mesh: mesh, view: parameters.view,
                                                    options: parameters.options) else {
        print("drawing FAILED")
        return
    }
    let visible = drawing.paths.count { $0.kind == .visible }
    print("\(mesh.triangles.count) triangles → \(visible) visible + "
        + "\(drawing.paths.count - visible) hidden paths")

    let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    guard let bitmap = await renderDisplayBitmap(for: drawing, lineWidth: 1.5) else {
        print("render FAILED")
        return
    }
    let pngURL = directory.appendingPathComponent("hero.png")
    if let destination = CGImageDestinationCreateWithURL(pngURL as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1, nil) {
        CGImageDestinationAddImage(destination, bitmap, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(pngURL.path)")
    }

    let maxDimension = Swift.max(drawing.bounds.size.x, drawing.bounds.size.y)
    let unit = maxDimension > 0 ? maxDimension / 1000 : 1
    let svg = drawing.svg(strokeWidth: 1.5 * unit,
                          hiddenDashPattern: [6 * unit, 4 * unit],
                          margin: 12 * unit)
    try? Data(svg.utf8).write(to: directory.appendingPathComponent("hero.svg"))
    print("wrote \(directory.appendingPathComponent("hero.svg").path)")
}

// MARK: - Headless benchmark

private func runBenchmark(path: String) async {
    let clock = ContinuousClock()
    var diagnostics = MeshDiagnostics()
    print("importing \(path) …")
    var imported: Mesh?
    let importTime = clock.measure {
        imported = try? MeshImport.mesh(contentsOf: URL(fileURLWithPath: path),
                                        diagnostics: &diagnostics)
    }
    guard let mesh = imported else {
        print("import FAILED")
        return
    }
    print("import: \(importTime) — \(mesh.triangles.count) triangles, "
        + "\(mesh.positions.count) vertices, \(diagnostics.boundaryEdgeCount) boundary edges, "
        + "\(diagnostics.nonManifoldEdgeCount) non-manifold")

    for (name, view) in [("front", OrthographicView.front), ("isometric", .isometric)] {
        var drawing: LineDrawing?
        let drawTime = clock.measure {
            drawing = makeLineDrawing(mesh: mesh, view: view)  // serial path
        }
        let visible = drawing?.paths.count { $0.kind == .visible } ?? 0
        let hidden = (drawing?.paths.count ?? 0) - visible
        let renderStart = clock.now
        let bitmap = drawing == nil ? nil : await renderDisplayBitmap(for: drawing!)
        let renderTime = clock.now - renderStart
        print("\(name): \(drawTime) — \(visible) visible + \(hidden) hidden paths; "
            + "display render \(renderTime) (\(bitmap == nil ? "FAILED" : "ok"))")
    }
}

// MARK: - Display rasterizer

/// Geometry of the display bitmap (~1600px long side).
private struct DisplayLayout: Sendable {
    let scale: Double
    let margin = 24.0
    let width: Int
    let height: Int
    let boundsMin: SIMD2<Double>

    init?(drawing: LineDrawing) {
        let maxDimension = Swift.max(drawing.bounds.size.x, drawing.bounds.size.y)
        guard !drawing.paths.isEmpty, maxDimension > 0 else { return nil }
        scale = 1600 / maxDimension
        width = Int((drawing.bounds.size.x * scale + 2 * margin).rounded(.up))
        height = Int((drawing.bounds.size.y * scale + 2 * margin).rounded(.up))
        boundsMin = drawing.bounds.min
    }

    func apply(to context: CGContext) {
        context.translateBy(x: CGFloat(margin), y: CGFloat(margin))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: CGFloat(-boundsMin.x), y: CGFloat(-boundsMin.y))
        context.setLineCap(.butt)
        context.setLineJoin(.miter)
    }
}

private struct StrokeStyle: Sendable {
    var gray: Double
    var width: Double        // pixels
    var dash: [Double]       // pixels; empty = solid
    /// Antialiasing is disabled for enormous drawings — AA dominates
    /// thin-line stroking cost, and preview jaggies beat multi-second waits.
    var antialiased = true
}

/// Renders a drawing into a display bitmap. CoreGraphics stroking of
/// scan-scale drawings (500k+ subpaths) takes tens of seconds in a single
/// context, so the paths are split across parallel transparent layers that
/// stroke concurrently and composite at the end (hidden under visible —
/// same-style layers composite order-free). Cancellation is checked between
/// stroke batches, so superseded renders abort quickly.
private func renderDisplayBitmap(for drawing: LineDrawing,
                                 lineWidth: Double = 1.6) async -> CGImage? {
    guard let layout = DisplayLayout(drawing: drawing) else { return nil }
    let hidden = drawing.paths.filter { $0.kind == .hidden }
    let visible = drawing.paths.filter { $0.kind == .visible }
    // Dashing hundreds of thousands of subpaths is pathological in CG; a
    // thin gray solid line reads as "hidden" at a fraction of the cost.
    let antialiased = drawing.paths.count <= 150_000
    let hiddenWidth = lineWidth * 0.625
    let hiddenStyle = hidden.count <= 30_000
        ? StrokeStyle(gray: 0, width: hiddenWidth, dash: [6, 4], antialiased: antialiased)
        : StrokeStyle(gray: 0.55, width: hiddenWidth, dash: [], antialiased: antialiased)
    let visibleStyle = StrokeStyle(gray: 0, width: lineWidth, dash: [], antialiased: antialiased)

    let layerSlices = slices(hidden, style: hiddenStyle, from: 0)
        + slices(visible, style: visibleStyle, from: 1_000)

    return await withTaskGroup(of: CGImage??.self) { group in
        group.addTask {
            await renderLayersAndComposite(layerSlices, layout: layout)
        }
        return await group.next().flatMap { $0 } ?? nil
    }
}

private func slices(_ paths: [LineDrawing.Path],
                    style: StrokeStyle,
                    from orderBase: Int) -> [(order: Int, style: StrokeStyle, paths: [LineDrawing.Path])] {
    guard !paths.isEmpty else { return [] }
    let sliceCount = Swift.min(8, Swift.max(1, paths.count / 8_000))
    let sliceSize = (paths.count + sliceCount - 1) / sliceCount
    return stride(from: 0, to: paths.count, by: sliceSize).enumerated().map { index, start in
        (orderBase + index, style, Array(paths[start..<Swift.min(start + sliceSize, paths.count)]))
    }
}

private func renderLayersAndComposite(
    _ layers: [(order: Int, style: StrokeStyle, paths: [LineDrawing.Path])],
    layout: DisplayLayout
) async -> CGImage? {
    let rendered: [(Int, CGImage)]? = await withTaskGroup(of: (Int, CGImage?).self) { group in
        for layer in layers {
            group.addTask {
                (layer.order, renderLayer(layer.paths, style: layer.style, layout: layout))
            }
        }
        var collected: [(Int, CGImage)] = []
        for await (order, image) in group {
            guard let image else {
                group.cancelAll()
                return nil
            }
            collected.append((order, image))
        }
        return collected
    }
    guard var images = rendered else { return nil }
    images.sort { $0.0 < $1.0 }  // hidden layers first, then visible

    guard let base = CGContext(
        data: nil, width: layout.width, height: layout.height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let full = CGRect(x: 0, y: 0, width: CGFloat(layout.width), height: CGFloat(layout.height))
    base.setFillColor(CGColor(gray: 1, alpha: 1))
    base.fill(full)
    for (_, image) in images {
        if Task.isCancelled { return nil }
        base.draw(image, in: full)
    }
    return base.makeImage()
}

/// One transparent layer, stroked in cancellation-checked batches.
private func renderLayer(_ paths: [LineDrawing.Path],
                         style: StrokeStyle,
                         layout: DisplayLayout) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: layout.width, height: layout.height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    layout.apply(to: context)
    context.setShouldAntialias(style.antialiased)
    context.setStrokeColor(CGColor(gray: style.gray, alpha: 1))
    context.setLineWidth(CGFloat(style.width / layout.scale))
    if !style.dash.isEmpty {
        context.setLineDash(phase: 0, lengths: style.dash.map { CGFloat($0 / layout.scale) })
    }

    var index = 0
    while index < paths.count {
        if Task.isCancelled { return nil }
        let batch = CGMutablePath()
        for path in paths[index..<Swift.min(index + 10_000, paths.count)] {
            guard let first = path.points.first else { continue }
            batch.move(to: CGPoint(x: first.x, y: first.y))
            for point in path.points.dropFirst() {
                batch.addLine(to: CGPoint(x: point.x, y: point.y))
            }
        }
        context.addPath(batch)
        context.strokePath()
        index += 10_000
    }
    return context.makeImage()
}

// MARK: - App

struct DraftingDemoApp: App {
    var body: some Scene {
        WindowGroup("DraftingKit Demo") {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    // swift-run executables launch as background processes.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
    }
}

/// Everything that determines the drawing — .task(id:) recomputes on change.
struct DrawingParameters: Equatable {
    var meshStamp: Int = 0
    var azimuthDegrees: Double = -55
    var elevationDegrees: Double = 35
    var includeHiddenLines = true
    var suppressCoincident = true
    var creaseAngleDegrees: Double = 30
    /// sampleSpacingFraction = 1 / sampleDensity.
    var sampleDensity: Double = 512
    /// epsilonFraction = 10^epsilonExponent.
    var epsilonExponent: Double = -6

    /// Viewer orbits a Z-up model: azimuth around Z (0° = +X side),
    /// elevation up from the horizon. forward points INTO the scene.
    var view: OrthographicView {
        let azimuth = azimuthDegrees * .pi / 180
        let elevation = elevationDegrees * .pi / 180
        let viewer = SIMD3(
            cos(elevation) * cos(azimuth),
            cos(elevation) * sin(azimuth),
            sin(elevation)
        )
        return OrthographicView(forward: -viewer, up: SIMD3(0, 0, 1))
    }

    var options: DrawingOptions {
        var options = DrawingOptions()
        options.includeHiddenLines = includeHiddenLines
        options.suppressHiddenCoincidentWithVisible = suppressCoincident
        options.creaseAngleDegrees = creaseAngleDegrees
        options.sampleSpacingFraction = 1 / sampleDensity
        options.epsilonFraction = pow(10, epsilonExponent)
        return options
    }
}

struct ContentView: View {
    @State private var mesh: Mesh?
    @State private var meshInfo = ""
    @State private var diagnosticsInfo = ""
    @State private var errorMessage = ""
    @State private var parameters = DrawingParameters()
    @State private var drawing: LineDrawing?
    @State private var image: NSImage?
    @State private var computeInfo = ""
    @State private var exportScale = "72"
    @State private var importerShown = false
    @State private var importing = false
    @State private var computing = false
    /// Stale-result guards: bumped whenever a compute/render starts; results
    /// from an older generation are discarded (makeLineDrawing itself is not
    /// cancellable mid-flight).
    @State private var computeGeneration = 0
    @State private var renderGeneration = 0
    /// Visible stroke width in display pixels / export points; hidden lines
    /// render at 62.5% of it.
    @State private var lineWidth = 1.6

    private let modelTypes: [UTType] = [
        UTType(filenameExtension: "stl"),
        UTType(filenameExtension: "obj"),
        UTType(filenameExtension: "usdz"),
    ].compactMap { $0 }

    var body: some View {
        HSplitView {
            controls
                .frame(width: 320)
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: parameters) {
            // Debounce slider drags; cancellation during the sleep means a
            // newer parameter change superseded this one.
            guard mesh != nil else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await recompute()
        }
        .task(id: lineWidth) {
            // Width changes only re-render the cached drawing.
            guard drawing != nil else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            await rerender()
        }
    }

    // MARK: Sidebar

    private var controls: some View {
        Form {
            Section("Model") {
                Button("Open Model… (STL / OBJ / USDZ)") { importerShown = true }
                    .fileImporter(isPresented: $importerShown,
                                  allowedContentTypes: modelTypes) { result in
                        if case .success(let url) = result {
                            Task { await load(url) }
                        }
                    }
                    .disabled(importing)
                if importing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Importing…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !meshInfo.isEmpty {
                    Text(meshInfo).font(.caption).foregroundStyle(.secondary)
                }
                if !diagnosticsInfo.isEmpty {
                    Text(diagnosticsInfo).font(.caption).foregroundStyle(.secondary)
                }
                if !errorMessage.isEmpty {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }

            Section("View") {
                LabeledContent("Presets") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            preset("Front", az: -90, el: 0)
                            preset("Back", az: 90, el: 0)
                            preset("Right", az: 0, el: 0)
                            preset("Left", az: 180, el: 0)
                        }
                        HStack {
                            preset("Top", az: -90, el: 90)
                            preset("Bottom", az: -90, el: -90)
                            preset("Iso", az: -55, el: 35)
                        }
                    }
                }
                slider("Azimuth", $parameters.azimuthDegrees, -180...180)
                slider("Elevation", $parameters.elevationDegrees, -90...90)
            }

            Section("Options") {
                Toggle("Hidden lines", isOn: $parameters.includeHiddenLines)
                Toggle("Suppress coincident hidden", isOn: $parameters.suppressCoincident)
                    .disabled(!parameters.includeHiddenLines)
                slider("Crease angle", $parameters.creaseAngleDegrees, 0...120)
                Picker("Sampling (diag ÷ n)", selection: $parameters.sampleDensity) {
                    Text("256").tag(256.0)
                    Text("512").tag(512.0)
                    Text("1024").tag(1024.0)
                    Text("2048").tag(2048.0)
                }
                .pickerStyle(.segmented)
                Picker("Depth ε (× diag)", selection: $parameters.epsilonExponent) {
                    Text("1e-6").tag(-6.0)
                    Text("1e-5").tag(-5.0)
                    Text("1e-4").tag(-4.0)
                    Text("1e-3").tag(-3.0)
                }
                .pickerStyle(.segmented)
            }

            Section("Drawing") {
                if !computeInfo.isEmpty {
                    Text(computeInfo).font(.caption).foregroundStyle(.secondary)
                }
                slider("Line width", $lineWidth, 0.4...4.0,
                       format: { String(format: "%.1f", $0) })
                LabeledContent("Export scale") {
                    HStack(spacing: 4) {
                        TextField("", text: $exportScale)
                            .frame(width: 64)
                        Text("pt / unit").font(.caption).foregroundStyle(.secondary)
                        Button("Fit") { fitExportScale() }
                            .controlSize(.small)
                            .help("Scale so the drawing's long side is ~1000pt (fits on paper; PDF pages cap at 14,400pt)")
                    }
                }
                HStack {
                    Button("Save PDF…") { savePDF() }
                    Button("Save SVG…") { saveSVG() }
                }
                .disabled(drawing == nil)
            }
        }
        .formStyle(.grouped)
    }

    private func preset(_ label: String, az: Double, el: Double) -> some View {
        Button(label) {
            parameters.azimuthDegrees = az
            parameters.elevationDegrees = el
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func slider(_ label: String,
                        _ value: Binding<Double>,
                        _ range: ClosedRange<Double>,
                        format: @escaping (Double) -> String = { "\(Int($0))°" }) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: range)
                Text(format(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack {
            Rectangle().fill(.white)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
            } else if !computing {
                Text(mesh == nil
                     ? "Open an STL, OBJ or USDZ file to begin."
                     : "Nothing to draw for this view.")
                    .foregroundStyle(.gray)
            }
            if computing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Computing drawing…").font(.caption).foregroundStyle(.gray)
                }
                .padding(20)
                .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Actions

    /// Import runs off the main actor; the UI shows progress meanwhile.
    private func load(_ url: URL) async {
        importing = true
        errorMessage = ""
        defer { importing = false }
        do {
            let (loaded, diagnostics, elapsed) = try await Self.importMesh(url)
            mesh = loaded
            // Default the export scale to something printable: a 600mm model
            // at 72 pt/unit would be a ~43,000pt page — past the 14,400pt
            // PDF limit and blank-looking in viewers.
            let box = loaded.boundingBox
            let extent = box.max - box.min
            let maxDimension = Swift.max(extent.x, Swift.max(extent.y, extent.z))
            if maxDimension > 0 {
                exportScale = String(format: "%.3g", 1000 / maxDimension)
            }
            meshInfo = "\(url.lastPathComponent) — \(loaded.triangles.count) triangles, "
                + "\(loaded.positions.count) vertices (\(Self.seconds(elapsed)))"
            diagnosticsInfo = "dropped \(diagnostics.degenerateTrianglesDropped) degenerate, "
                + "\(diagnostics.boundaryEdgeCount) boundary edges, "
                + "\(diagnostics.nonManifoldEdgeCount) non-manifold edges"
            parameters.meshStamp += 1
        } catch {
            errorMessage = "Import failed: \(error)"
        }
    }

    /// Import in a child task: child tasks always run on the global executor,
    /// unlike nonisolated async functions, which run on the CALLER's actor —
    /// on this toolchain that means the main thread.
    private nonisolated static func importMesh(_ url: URL) async throws
        -> (Mesh, MeshDiagnostics, Duration)
    {
        try await withThrowingTaskGroup(of: (Mesh, MeshDiagnostics, Duration).self) { group in
            group.addTask {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                var diagnostics = MeshDiagnostics()
                let clock = ContinuousClock()
                let start = clock.now
                let mesh = try MeshImport.mesh(contentsOf: url, diagnostics: &diagnostics)
                return (mesh, diagnostics, clock.now - start)
            }
            return try await group.next()!
        }
    }

    private func recompute() async {
        guard let mesh else {
            drawing = nil
            image = nil
            return
        }
        computeGeneration += 1
        let generation = computeGeneration
        computing = true

        let clock = ContinuousClock()
        let start = clock.now
        let result: LineDrawing
        do {
            result = try await makeLineDrawing(mesh: mesh, view: parameters.view,
                                               options: parameters.options)
        } catch {
            // Cancelled: .task(id:) superseded this run — the library now
            // stops computing within milliseconds instead of running to
            // completion and being discarded.
            return
        }
        let computeElapsed = clock.now - start
        // A newer compute superseded this one while it was in flight.
        guard generation == computeGeneration else { return }
        drawing = result

        // Rasterize in a child task (global executor, inherits cancellation)
        // — at scan scale a drawing can hold hundreds of thousands of paths,
        // and stroking those on main is a beachball. The main thread only
        // wraps the finished bitmap.
        renderGeneration += 1
        let render = renderGeneration
        let rendered = await Self.renderOffMain(result, lineWidth: lineWidth)
        guard generation == computeGeneration, render == renderGeneration else { return }
        computing = false
        image = rendered.map { NSImage(cgImage: $0, size: .zero) }
        let visible = result.paths.count { $0.kind == .visible }
        let hidden = result.paths.count - visible
        computeInfo = "\(visible) visible + \(hidden) hidden paths in \(Self.seconds(computeElapsed)) "
            + "(+ \(Self.seconds(clock.now - start - computeElapsed)) render)"
    }

    /// Re-render the cached drawing (line width changed) — no pipeline run.
    private func rerender() async {
        guard let drawing else { return }
        renderGeneration += 1
        let render = renderGeneration
        computing = true
        let rendered = await Self.renderOffMain(drawing, lineWidth: lineWidth)
        guard render == renderGeneration else { return }
        computing = false
        if let rendered {
            image = NSImage(cgImage: rendered, size: .zero)
        }
    }

    /// The rasterizer runs its work in child tasks (global executor) and
    /// inherits cancellation from the surrounding .task, so a superseded
    /// render aborts at the next batch boundary.
    private nonisolated static func renderOffMain(_ drawing: LineDrawing,
                                                  lineWidth: Double) async -> CGImage? {
        await renderDisplayBitmap(for: drawing, lineWidth: lineWidth)
    }

    private static func seconds(_ duration: Duration) -> String {
        let s = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", s)
    }

    /// Scale so the CURRENT drawing's long side lands at ~1000pt.
    private func fitExportScale() {
        guard let drawing else { return }
        let maxDimension = Swift.max(drawing.bounds.size.x, drawing.bounds.size.y)
        guard maxDimension > 0 else { return }
        exportScale = String(format: "%.3g", 1000 / maxDimension)
    }

    private func savePDF() {
        guard let drawing else { return }
        let scale = Double(exportScale) ?? 72
        var mutableStyle = PDFStyle(pointsPerModelUnit: scale)
        mutableStyle.margin = 18
        mutableStyle.visibleLineWidth = lineWidth
        mutableStyle.hiddenLineWidth = lineWidth * 0.625
        let style = mutableStyle
        save(type: .pdf, name: "drawing.pdf") { drawing.pdfData(style: style) }
    }

    private func saveSVG() {
        guard let drawing else { return }
        // SVG lengths are in model units (like its viewBox); scale widths
        // and dashes to the drawing size so browsers show the same weight
        // as the canvas (1 "display point" ≈ maxDimension / 1000).
        let maxDimension = Swift.max(drawing.bounds.size.x, drawing.bounds.size.y)
        let unit = maxDimension > 0 ? maxDimension / 1000 : 1
        let strokeWidth = lineWidth * unit
        let dashes = [6 * unit, 4 * unit]
        let margin = 12 * unit
        save(type: .svg, name: "drawing.svg") {
            Data(drawing.svg(strokeWidth: strokeWidth,
                             hiddenDashPattern: dashes,
                             margin: margin).utf8)
        }
    }

    /// Panel on main; encoding + writing off main (a scan-scale drawing takes
    /// seconds to serialize).
    private func save(type: UTType, name: String,
                      encode: @escaping @Sendable () -> Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        errorMessage = ""
        Task {
            let data = await Self.encoded(encode)
            do {
                try data.write(to: url)
            } catch {
                errorMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    /// Runs the (potentially seconds-long) serialization off the main actor.
    private nonisolated static func encoded(_ encode: @Sendable () -> Data) async -> Data {
        encode()
    }
}

#else

@main
struct DraftingDemoStub {
    static func main() {
        print("DraftingDemo is a macOS-only manual test harness.")
    }
}

#endif
