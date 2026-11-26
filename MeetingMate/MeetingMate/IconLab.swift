#if DEBUG
import SwiftUI
import AppKit

/// Debug-only window to compare the three mark variants, tune parameters and export.
/// Opened from the menu bar: "Icon Lab…" (Debug builds only).
struct IconLabView: View {
    @State private var params = LangMarkParams()
    @State private var message = ""

    private let systemApps: [(name: String, path: String)] = [
        ("Finder", "/System/Library/CoreServices/Finder.app"),
        ("Notes", "/System/Applications/Notes.app"),
        ("Voice Memos", "/System/Applications/Voice Memos.app"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { controls.padding(16) }
                .frame(width: 290)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    ForEach(LangVariant.allCases) { variantSection($0) }
                    dockComparison
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 1280, minHeight: 860)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tham số").font(.headline)
            slider("Bowl width", $params.bowlWidth, 0.3...0.8)
            slider("Bowl depth", $params.bowlDepth, 0.08...0.3)
            slider("Wall thickness", $params.wallThickness, 0.02...0.09)
            Picker("Số lớp", selection: $params.layerCount) {
                Text("2").tag(2)
                Text("3").tag(3)
            }
            .pickerStyle(.segmented)
            slider("Bar height", $params.layerHeight, 0.015...0.05)
            slider("Wobble", $params.wobble, 0...0.012)
            slider("Drop angle (°)", $params.dropAngle, 0...60)
            slider("Drop X", $params.dropOffsetX, -0.2...0.2)
            slider("Drop Y", $params.dropOffsetY, -0.2...0.2)
            Toggle("Trail (2 chấm)", isOn: $params.showTrail)
            Toggle("Nền squircle", isOn: $params.showBackground)

            Divider()
            Text("Xuất").font(.headline)
            Picker("Biến thể để xuất", selection: $params.variant) {
                ForEach(LangVariant.allCases) { Text($0.title).tag($0) }
            }
            Button("Xuất AppIcon (PNG + Contents.json)…") {
                export("AppIcon") { try LangExporter.exportAppIcon(params, to: $0) }
            }
            Button("Xuất layers (PNG 1024 + SVG)…") {
                export("Layers") { try LangExporter.exportLayers(params, to: $0) }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.3f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func export(_ label: String, _ action: (URL) throws -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Chọn thư mục"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try action(url)
            message = "\(label) xong: \(url.path)"
        } catch {
            message = "Lỗi \(label): \(error.localizedDescription)"
        }
    }

    // MARK: Variants

    private func paramsFor(_ variant: LangVariant) -> LangMarkParams {
        var p = params
        p.variant = variant
        return p
    }

    private func variantSection(_ variant: LangVariant) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(variant.title).font(.title3.bold())
            sizeStrip(paramsFor(variant), dark: false)
            sizeStrip(paramsFor(variant), dark: true)
        }
    }

    /// 1024 is shown at 360 pt so the strip fits the window. Its real export size is 1024 px.
    private func sizeStrip(_ p: LangMarkParams, dark: Bool) -> some View {
        let sizes: [CGFloat] = [1024, 256, 128, 64, 32, 16]
        return HStack(alignment: .bottom, spacing: 18) {
            ForEach(sizes, id: \.self) { size in
                let shown: CGFloat = size == 1024 ? 360 : size
                VStack(spacing: 4) {
                    LangMark(params: p).frame(width: shown, height: shown)
                    Text(size == 1024 ? "1024 (hiện 360 pt)" : "\(Int(size))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dark ? Color(white: 0.13) : Color(white: 0.92),
                    in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    // MARK: Dock comparison

    private var dockComparison: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("So sánh với icon Dock (64 pt)").font(.title3.bold())
            ForEach([false, true], id: \.self) { dark in
                HStack(alignment: .bottom, spacing: 22) {
                    ForEach(systemApps, id: \.path) { app in
                        VStack(spacing: 4) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 64, height: 64)
                            Text(app.name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(LangVariant.allCases) { variant in
                        VStack(spacing: 4) {
                            LangMark(params: paramsFor(variant)).frame(width: 64, height: 64)
                            Text(variant.title).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(dark ? Color(white: 0.13) : Color(white: 0.92),
                            in: RoundedRectangle(cornerRadius: 14))
                .environment(\.colorScheme, dark ? .dark : .light)
            }
        }
    }
}
#endif
