// WireframeDemo — dead-simple manual test harness for WireframeKit.
//
//   swift run -c release WireframeDemo                  (GUI)
//   swift run -c release WireframeDemo bench <file>     (headless timings)
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
import WireframeCore
import WireframeGraphics
import WireframeModelIO

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count >= 3, arguments[1] == "bench" {
            runBenchmark(path: arguments[2])
        } else {
            WireframeDemoApp.main()
        }
    }
}

// MARK: - Headless benchmark

private func runBenchmark(path: String) {
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
        print("\(name): \(drawTime) — \(visible) visible + \(hidden) hidden paths")
    }
}

// MARK: - App

struct WireframeDemoApp: App {
    var body: some Scene {
        WindowGroup("WireframeKit Demo") {
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
    /// Stale-result guard: bumped whenever a compute task starts; results
    /// from an older generation are discarded (makeLineDrawing itself is not
    /// cancellable mid-flight).
    @State private var computeGeneration = 0

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
                LabeledContent("Export scale") {
                    HStack(spacing: 4) {
                        TextField("", text: $exportScale)
                            .frame(width: 64)
                        Text("pt / unit").font(.caption).foregroundStyle(.secondary)
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
                        _ range: ClosedRange<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: range)
                Text("\(Int(value.wrappedValue))°")
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

    /// nonisolated async ⇒ runs on the cooperative pool, not the main actor.
    private nonisolated static func importMesh(_ url: URL) async throws
        -> (Mesh, MeshDiagnostics, Duration)
    {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var diagnostics = MeshDiagnostics()
        let clock = ContinuousClock()
        let start = clock.now
        let mesh = try MeshImport.mesh(contentsOf: url, diagnostics: &diagnostics)
        return (mesh, diagnostics, clock.now - start)
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
        let result = await makeLineDrawing(mesh: mesh, view: parameters.view,
                                           options: parameters.options)
        let computeElapsed = clock.now - start
        // A newer compute superseded this one while it was in flight.
        guard generation == computeGeneration else { return }
        drawing = result

        // Rasterize off the main actor — at scan scale a drawing can hold
        // hundreds of thousands of paths, and stroking those on main is a
        // beachball. The main thread only wraps the finished bitmap.
        let rendered = await Self.renderBitmap(for: result)
        guard generation == computeGeneration else { return }
        computing = false
        image = rendered.map { NSImage(cgImage: $0, size: .zero) }
        let visible = result.paths.count { $0.kind == .visible }
        let hidden = result.paths.count - visible
        computeInfo = "\(visible) visible + \(hidden) hidden paths in \(Self.seconds(computeElapsed)) "
            + "(+ \(Self.seconds(clock.now - start - computeElapsed)) render)"
    }

    /// Renders the drawing into a bitmap sized ~2200px on the long side,
    /// off the main actor (nonisolated async ⇒ cooperative pool). Display
    /// only — export still goes through the vector PDF/SVG paths.
    private nonisolated static func renderBitmap(for drawing: LineDrawing) async -> CGImage? {
        guard !drawing.paths.isEmpty else { return nil }
        let maxDimension = Swift.max(drawing.bounds.size.x, drawing.bounds.size.y)
        guard maxDimension > 0 else { return nil }
        let scale = 2200 / maxDimension
        let margin = 24.0
        let width = Int((drawing.bounds.size.x * scale + 2 * margin).rounded(.up))
        let height = Int((drawing.bounds.size.y * scale + 2 * margin).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.translateBy(x: CGFloat(margin), y: CGFloat(margin))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: CGFloat(-drawing.bounds.min.x), y: CGFloat(-drawing.bounds.min.y))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let hidden = drawing.cgPath(for: .hidden)
        if !hidden.isEmpty {
            context.setLineWidth(CGFloat(1.0 / scale))
            context.setLineDash(phase: 0, lengths: [CGFloat(6 / scale), CGFloat(4 / scale)])
            context.addPath(hidden)
            context.strokePath()
        }
        let visible = drawing.cgPath(for: .visible)
        if !visible.isEmpty {
            context.setLineWidth(CGFloat(1.6 / scale))
            context.setLineDash(phase: 0, lengths: [])
            context.addPath(visible)
            context.strokePath()
        }
        return context.makeImage()
    }

    private static func seconds(_ duration: Duration) -> String {
        let s = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", s)
    }

    private func savePDF() {
        guard let drawing else { return }
        let scale = Double(exportScale) ?? 72
        var mutableStyle = PDFStyle(pointsPerModelUnit: scale)
        mutableStyle.margin = 18
        let style = mutableStyle
        save(type: .pdf, name: "wireframe.pdf") { drawing.pdfData(style: style) }
    }

    private func saveSVG() {
        guard let drawing else { return }
        save(type: .svg, name: "wireframe.svg") { Data(drawing.svg().utf8) }
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
struct WireframeDemoStub {
    static func main() {
        print("WireframeDemo is a macOS-only manual test harness.")
    }
}

#endif
