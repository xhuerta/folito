import SwiftUI
import ReaderCore

/// Typography controls with a live preview. Reached from the reader menu and from Settings.
struct TypographyEditorView: View {
    @EnvironmentObject private var typography: TypographyModel

    var body: some View {
        List {
            Section("Preview") {
                TypographyPreview(typography: typography.value)
                    .listRowInsets(EdgeInsets())
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Section("Presets") {
                ForEach(ReaderTypography.Preset.allCases, id: \.self) { preset in
                    Button(preset.title) { typography.apply(preset) }
                }
            }
            Section("Font") {
                Picker("Font", selection: typography.binding(\.fontFamily)) {
                    ForEach(ReaderTypography.FontFamily.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Stepper(value: typography.binding(\.fontSize), in: ReaderTypography.fontSizeRange, step: 1) {
                    row("Size", "\(Int(typography.value.fontSize)) pt")
                }
                Toggle("Bold text", isOn: typography.binding(\.boldText))
                Stepper(value: typography.binding(\.headingScale), in: ReaderTypography.headingScaleRange, step: 0.25) {
                    row("Headings", "\(Int((typography.value.headingScale * 100).rounded()))%")
                }
                Stepper(value: typography.binding(\.tracking), in: ReaderTypography.trackingRange, step: 0.25) {
                    row("Letter spacing", String(format: "%+.2f", typography.value.tracking))
                }
            }
            Section("Layout") {
                Stepper(value: typography.binding(\.lineSpacing), in: ReaderTypography.lineSpacingRange, step: 1) {
                    row("Line spacing", "\(Int(typography.value.lineSpacing))")
                }
                Stepper(value: typography.binding(\.paragraphSpacing), in: ReaderTypography.paragraphSpacingRange, step: 2) {
                    row("Paragraph gap", "\(Int(typography.value.paragraphSpacing))")
                }
                Stepper(value: typography.binding(\.horizontalMargin), in: ReaderTypography.horizontalMarginRange, step: 2) {
                    row("Margins", "\(Int(typography.value.horizontalMargin))")
                }
                Picker("Alignment", selection: typography.binding(\.alignment)) {
                    ForEach(ReaderTypography.Alignment.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Theme") {
                Picker("Theme", selection: typography.binding(\.theme)) {
                    ForEach(ReaderTypography.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                Button("Reset to defaults", role: .destructive) { typography.reset() }
            }
        }
        .navigationTitle("Typography")
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
            Text(value).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
