// WireframeDemo — dead-simple manual test harness for WireframeKit.
//
//   swift run WireframeDemo
//
// Import an STL/OBJ/USDZ, aim the view with presets or azimuth/elevation
// sliders, and see the hidden-line drawing rendered through the REAL
// production path: makeLineDrawing → pdfData → NSImage. Not part of the
// library API; excluded from non-macOS builds.

#if os(macOS)

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WireframeCore
import WireframeGraphics
import WireframeModelIO

@main
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
        .task(id: parameters) { await recompute() }
    }

    // MARK: Sidebar

    private var controls: some View {
        Form {
            Section("Model") {
                Button("Open Model… (STL / OBJ / USDZ)") { importerShown = true }
                    .fileImporter(isPresented: $importerShown,
                                  allowedContentTypes: modelTypes) { result in
                        if case .success(let url) = result { load(url) }
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
            } else {
                Text(mesh == nil
                     ? "Open an STL, OBJ or USDZ file to begin."
                     : "Nothing to draw for this view.")
                    .foregroundStyle(.gray)
            }
        }
    }

    // MARK: Actions

    private func load(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        errorMessage = ""
        var diagnostics = MeshDiagnostics()
        do {
            let loaded = try MeshImport.mesh(contentsOf: url, diagnostics: &diagnostics)
            mesh = loaded
            meshInfo = "\(url.lastPathComponent) — \(loaded.triangles.count) triangles, "
                + "\(loaded.positions.count) vertices"
            diagnosticsInfo = "dropped \(diagnostics.degenerateTrianglesDropped) degenerate, "
                + "\(diagnostics.boundaryEdgeCount) boundary edges, "
                + "\(diagnostics.nonManifoldEdgeCount) non-manifold edges"
            parameters.meshStamp += 1
        } catch {
            errorMessage = "Import failed: \(error)"
        }
    }

    private func recompute() async {
        guard let mesh else {
            drawing = nil
            image = nil
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await makeLineDrawing(mesh: mesh, view: parameters.view,
                                           options: parameters.options)
        let elapsed = clock.now - start

        drawing = result
        // Display through the production contract: vector PDF → NSImage.
        let pdf = result.pdfData(style: PDFStyle(pointsPerModelUnit: 72))
        image = result.paths.isEmpty ? nil : NSImage(data: pdf)
        let visible = result.paths.count { $0.kind == .visible }
        let hidden = result.paths.count - visible
        computeInfo = "\(visible) visible + \(hidden) hidden paths in \(elapsed)"
    }

    private func savePDF() {
        guard let drawing else { return }
        let scale = Double(exportScale) ?? 72
        var style = PDFStyle(pointsPerModelUnit: scale)
        style.margin = 18
        save(data: drawing.pdfData(style: style), type: .pdf, name: "wireframe.pdf")
    }

    private func saveSVG() {
        guard let drawing else { return }
        save(data: Data(drawing.svg().utf8),
             type: UTType.svg,
             name: "wireframe.svg")
    }

    private func save(data: Data, type: UTType, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
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
