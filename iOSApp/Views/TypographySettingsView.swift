import SwiftUI
import ReaderCore

/// Reader typography with a live preview rendered by the same code as the watch reader.
/// Changes are pushed to the watch through the settings channel (see docs/WATCH_CONNECTIVITY.md).
struct TypographySettingsView: View {
    @ObservedObject var typography: TypographyModel

    var body: some View {
        Form {
            Section("Preview") {
                // Roughly the width of a 45 mm watch screen.
                TypographyPreview(typography: typography.value)
                    .frame(width: 184)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            Section("Presets") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(ReaderTypography.Preset.allCases, id: \.self) { preset in
                            Button(preset.title) { typography.apply(preset) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            Section("Font") {
                Picker("Font", selection: typography.binding(\.fontFamily)) {
                    ForEach(ReaderTypography.FontFamily.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Size", typography.binding(\.fontSize), ReaderTypography.fontSizeRange, 1) { "\(Int($0)) pt" }
                Toggle("Bold text", isOn: typography.binding(\.boldText))
                slider("Headings", typography.binding(\.headingScale), ReaderTypography.headingScaleRange, 0.25) { "\(Int(($0 * 100).rounded()))%" }
                slider("Letter spacing", typography.binding(\.tracking), ReaderTypography.trackingRange, 0.25) { String(format: "%+.2f", $0) }
            }
            Section("Layout") {
                slider("Line spacing", typography.binding(\.lineSpacing), ReaderTypography.lineSpacingRange, 1) { "\(Int($0))" }
                slider("Paragraph gap", typography.binding(\.paragraphSpacing), ReaderTypography.paragraphSpacingRange, 2) { "\(Int($0))" }
                slider("Margins", typography.binding(\.horizontalMargin), ReaderTypography.horizontalMarginRange, 2) { "\(Int($0))" }
                Picker("Alignment", selection: typography.binding(\.alignment)) {
                    ForEach(ReaderTypography.Alignment.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Theme") {
                Picker("Theme", selection: typography.binding(\.theme)) {
                    ForEach(ReaderTypography.Theme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section(footer: Text("Justified text and automatic hyphenation are not available in SwiftUI on watchOS. Changes are sent to the watch; if you also change them on the watch, the most recent change wins.")) {
                Button("Reset to defaults", role: .destructive) { typography.reset() }
            }
        }
        .navigationTitle("Reading")
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double,
                        _ format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(format(value.wrappedValue)).foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step)
        }
    }
}

#Preview {
    NavigationStack {
        TypographySettingsView(typography: TypographyModel(store: TypographyStore(defaults: UserDefaults(suiteName: "preview") ?? .standard)))
    }
}
