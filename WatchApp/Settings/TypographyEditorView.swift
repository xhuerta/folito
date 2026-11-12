import SwiftUI
import ReaderCore

/// Typography controls with a live preview. Reached from the reader menu and from Settings.
struct TypographyEditorView: View {
    @EnvironmentObject private var typography: TypographyModel
    private var readerAccessibility = ReaderAccessibilityReader()
    @State private var confirmReset = false

    var body: some View {
        let t = typography.value
        List {
            Section("Preview") {
                // Rendered with this watch's accessibility settings, exactly like the reader.
                TypographyPreview(typography: t, accessibility: readerAccessibility.value)
                    .listRowInsets(EdgeInsets())
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Text preview"))
                    .accessibilityIdentifier("typographyPreview")
            }
            Section("Presets") {
                ForEach(ReaderTypography.Preset.allCases, id: \.self) { preset in
                    Button(preset.localizedName) { typography.apply(preset) }
                }
            }
            Section {
                Picker("Font", selection: typography.binding(\.fontFamily)) {
                    ForEach(ReaderTypography.FontFamily.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }
                TextSizeStepper()
                Toggle("Match System Text Size", isOn: typography.binding(\.matchSystemTextSize))
                Toggle("Bold Text", isOn: typography.binding(\.boldText))
                row(Text("Headings")) {
                    Stepper(value: typography.binding(\.headingScale), in: ReaderTypography.headingScaleRange, step: 0.25) {
                        SettingStepperValue(Text(verbatim: t.headingScale.formatted(.percent.precision(.fractionLength(0)))))
                    }
                    .accessibilityLabel(Text("Heading Size"))
                    .accessibilityValue(Text(t.headingScale.formatted(.percent.precision(.fractionLength(0)))))
                }
                row(Text("Letter Spacing")) {
                    Stepper(value: typography.binding(\.tracking), in: ReaderTypography.trackingRange, step: 0.25) {
                        SettingStepperValue(Text(verbatim: Self.signed(t.tracking)))
                    }
                    .accessibilityLabel(Text("Letter Spacing"))
                    .accessibilityValue(Text("\(Self.signed(t.tracking)) points", comment: "VoiceOver value of letter spacing, e.g. '+0.25 points'"))
                }
            } header: {
                Text("Font")
            } footer: {
                Text("With Match System Text Size on, the text size follows the Text Size setting of your Apple Watch, starting from the size above.")
            }
            Section("Layout") {
                row(Text("Line Spacing")) {
                    Stepper(value: typography.binding(\.lineSpacing), in: ReaderTypography.lineSpacingRange, step: 1) {
                        SettingStepperValue(Text(verbatim: Self.points(t.lineSpacing)))
                    }
                    .accessibilityLabel(Text("Line Spacing"))
                    .accessibilityValue(Text("\(Int(t.lineSpacing)) points", comment: "VoiceOver value of a spacing in points"))
                }
                row(Text("Paragraph Spacing")) {
                    Stepper(value: typography.binding(\.paragraphSpacing), in: ReaderTypography.paragraphSpacingRange, step: 2) {
                        SettingStepperValue(Text(verbatim: Self.points(t.paragraphSpacing)))
                    }
                    .accessibilityLabel(Text("Paragraph Spacing"))
                    .accessibilityValue(Text("\(Int(t.paragraphSpacing)) points", comment: "VoiceOver value of a spacing in points"))
                }
                row(Text("Margins")) {
                    Stepper(value: typography.binding(\.horizontalMargin), in: ReaderTypography.horizontalMarginRange, step: 2) {
                        SettingStepperValue(Text(verbatim: Self.points(t.horizontalMargin)))
                    }
                    .accessibilityLabel(Text("Margins"))
                    .accessibilityValue(Text("\(Int(t.horizontalMargin)) points", comment: "VoiceOver value of a spacing in points"))
                }
                Picker("Alignment", selection: typography.binding(\.alignment)) {
                    ForEach(ReaderTypography.Alignment.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }
            }
            Section {
                Picker("Theme", selection: typography.binding(\.theme)) {
                    ForEach(ReaderTypography.Theme.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("With Increase Contrast on, every theme uses stronger colors. Bold Text also makes the book text bold.")
            }
            Section {
                Button("Reset to Defaults", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Typography")
        .confirmationDialog("Reset typography to the defaults? This also changes it on your iPhone.",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { typography.reset() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// "+0.25" / "−0.50" in the user's locale.
    static func signed(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
    }

    static func points(_ value: Double) -> String {
        String(localized: "\(Int(value)) pt", comment: "A length in typographic points, e.g. '4 pt'")
    }

    /// Title above, value between − and +: see `SettingStepperRow`.
    private func row<Control: View>(_ title: Text, @ViewBuilder _ control: () -> Control) -> some View {
        SettingStepperRow(title: title, control: control)
    }
}
