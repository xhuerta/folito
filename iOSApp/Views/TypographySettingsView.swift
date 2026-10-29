import SwiftUI
import ReaderCore

/// Reader typography with a live preview rendered by the same code as the watch reader.
/// Changes are pushed to the watch through the settings channel (see docs/WATCH_CONNECTIVITY.md).
struct TypographySettingsView: View {
    @ObservedObject var typography: TypographyModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                // Content, not chrome: rendered at the reader's own font size and theme colours, at roughly
                // the width of a 45 mm watch screen, exactly as the watch shows it.
                TypographyPreview(typography: typography.value)
                    .frame(width: 184)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Reading preview")
                    .accessibilityValue(ReadingSettingsText.previewSummary(typography.value))
                    .accessibilityIdentifier("typographyPreview")
            } header: {
                Text("Preview").foregroundStyle(.secondaryText)
            }
            Section {
                // A grid, not a horizontal scroll view: every preset stays fully on screen (a half-visible button
                // at the edge is unreadable), and at accessibility sizes the presets stack in one column.
                let columns = dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.flexible())]
                    : [GridItem(.adaptive(minimum: 130), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(ReaderTypography.Preset.allCases, id: \.self) { preset in
                        Button {
                            typography.apply(preset)
                        } label: {
                            Text(ReadingSettingsText.name(preset))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        // Primary label colour: the accent colour on the bordered button's gray fill measured
                        // 4.17:1, below 4.5:1.
                        .tint(.primary)
                        .accessibilityHint("Applies this reading style.")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Presets").foregroundStyle(.secondaryText)
            }
            Section {
                adaptivePicker("Font", selection: typography.binding(\.fontFamily),
                               options: ReaderTypography.FontFamily.allCases) { ReadingSettingsText.name($0) }
                slider("Size", typography.binding(\.fontSize), ReaderTypography.fontSizeRange, 1) {
                    DisplayFormat.points($0)
                }
                Toggle("Bold Text", isOn: typography.binding(\.boldText))
                slider("Headings", typography.binding(\.headingScale), ReaderTypography.headingScaleRange, 0.25) {
                    DisplayFormat.percent($0)
                }
                slider("Letter Spacing", typography.binding(\.tracking), ReaderTypography.trackingRange, 0.25) {
                    DisplayFormat.signedPoints($0)
                }
            } header: {
                Text("Font").foregroundStyle(.secondaryText)
            }
            Section {
                slider("Line Spacing", typography.binding(\.lineSpacing), ReaderTypography.lineSpacingRange, 1) {
                    DisplayFormat.points($0)
                }
                slider("Paragraph Spacing", typography.binding(\.paragraphSpacing), ReaderTypography.paragraphSpacingRange, 2) {
                    DisplayFormat.points($0)
                }
                slider("Margins", typography.binding(\.horizontalMargin), ReaderTypography.horizontalMarginRange, 2) {
                    DisplayFormat.points($0)
                }
                adaptivePicker("Alignment", selection: typography.binding(\.alignment),
                               options: ReaderTypography.Alignment.allCases) { ReadingSettingsText.name($0) }
            } header: {
                Text("Layout").foregroundStyle(.secondaryText)
            }
            Section {
                Picker("Theme", selection: typography.binding(\.theme)) {
                    ForEach(ReaderTypography.Theme.allCases, id: \.self) { Text(ReadingSettingsText.name($0)).tag($0) }
                }
            } header: {
                Text("Theme").foregroundStyle(.secondaryText)
            }
            Section {
                Button(role: .destructive) { confirmReset = true } label: {
                    Text("Reset to Defaults").foregroundStyle(.destructiveText)
                }
            } footer: {
                Text("Justified text and automatic hyphenation aren’t available on Apple Watch. Changes are sent to your watch; if you also change them on the watch, the most recent change wins.").foregroundStyle(.secondaryText)
            }
        }
        .readableScrollEdges()
        .navigationTitle("Reading")
        .confirmationDialog("Reset all reading settings to their defaults?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Reset to Defaults", role: .destructive) { typography.reset() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Segmented control at normal text sizes; a menu at accessibility sizes, where segments would truncate.
    @ViewBuilder
    private func adaptivePicker<Value: Hashable>(_ title: LocalizedStringKey, selection: Binding<Value>,
                                                 options: [Value], name: @escaping (Value) -> String) -> some View {
        let picker = Picker(title, selection: selection) {
            ForEach(options, id: \.self) { Text(name($0)).tag($0) }
        }
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    /// Title and current value above the slider (stacked at accessibility sizes). VoiceOver reads the
    /// slider once, as "title, value", and adjusts it by swiping up or down.
    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ step: Double, _ format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(format(value.wrappedValue)).foregroundStyle(.secondaryText)
                }
                VStack(alignment: .leading) {
                    Text(title)
                    Text(format(value.wrappedValue)).foregroundStyle(.secondaryText)
                }
            }
            .accessibilityHidden(true)
            Slider(value: value, in: range, step: step) {
                Text(title)
            }
            .accessibilityValue(format(value.wrappedValue))
        }
    }
}

#Preview {
    NavigationStack {
        TypographySettingsView(typography: TypographyModel(store: TypographyStore(defaults: UserDefaults(suiteName: "preview") ?? .standard)))
    }
}
