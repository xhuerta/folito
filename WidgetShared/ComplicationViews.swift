import SwiftUI
import WidgetKit

// Views of the Folito complications (watch faces) and Smart Stack widget. Compiled into both the widget
// extension (WatchWidgets/), which shows them, and the watch app, so FolitoWatchTests can render them to PNGs
// (ComplicationSnapshotTests, the CI "complication-screenshots" artifact). See docs/ACCESSIBILITY.md.
//
// HIG notes: system fonts and SF Symbols only; the gauge and the book symbol are `widgetAccentable` so a tinted
// watch face colours them and keeps the text white; titles are `privacySensitive` (hidden on a locked watch,
// only the percentage stays); with the wrist down (Always On) the accent is dimmed. Each family is a single
// VoiceOver element: "Folito, 45% of <title>".

enum ComplicationText {
    static let appName = "Folito"

    /// Whole percent for the user's locale, rounded down so an unfinished book never shows 100%.
    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        let whole = min((f * 100 + 1e-9).rounded(.down), 100) / 100
        return whole.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// Title for tight spaces: collapses whitespace and drops a subtitle ("Dune: Book One" -> "Dune",
    /// "Emma — A Novel" -> "Emma") when what remains is still a real title.
    static func shortTitle(_ title: String) -> String {
        let collapsed = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for separator in [": ", " — ", " – ", " - ", " ("] {
            if let range = collapsed.range(of: separator) {
                let head = collapsed[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if head.count >= 3 { return head }
            }
        }
        return collapsed
    }

    /// The inline complication ("45% · Title"); just the percentage when the title is redacted.
    static func inline(_ snapshot: ReadingSnapshot, title: String? = nil, locale: Locale = .current) -> String {
        let p = percent(snapshot.fraction, locale: locale)
        let title = title ?? snapshot.title
        guard !title.isEmpty else { return p }
        return "\(p) \u{00B7} \(title)"
    }

    static var startReading: String {
        String(localized: "Start reading", comment: "Complication shown when no book is in progress; tapping it opens the library")
    }

    static func minutesLeft(_ minutes: Int) -> String {
        String(localized: "\(minutes) min left in chapter",
               comment: "Complication: estimated reading time left in the current chapter. The argument is a number of minutes.")
    }

    /// VoiceOver label: "Folito, 45% of Pride and Prejudice" (VoiceOver reads "45 percent").
    static func accessibilityLabel(_ snapshot: ReadingSnapshot?, redacted: Bool, locale: Locale = .current) -> String {
        guard let snapshot else {
            return String(localized: "Folito, start reading",
                          comment: "VoiceOver label of the complication when no book is in progress")
        }
        let p = percent(snapshot.fraction, locale: locale)
        if redacted || snapshot.title.isEmpty {
            return String(localized: "Folito, \(p)",
                          comment: "VoiceOver label of the complication on a locked watch (title hidden). The argument is a formatted percentage.")
        }
        return String(localized: "Folito, \(p) of \(snapshot.title)",
                      comment: "VoiceOver label of the complication. Arguments: formatted percentage, book title.")
    }
}

extension Color {
    /// The app's accent colour (WatchApp/Assets.xcassets AccentColor), defined here so the extension needs no
    /// asset catalog of its own.
    static let folitoAccent = Color(red: 0.302, green: 0.651, blue: 1.0)
}

/// Overrides the accent colour when rendering screenshots of the tinted (accented) watch face, where the system
/// would otherwise paint the `widgetAccentable` parts itself. Never set in the widget extension.
struct ComplicationPreviewTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var complicationPreviewTint: Color? {
        get { self[ComplicationPreviewTintKey.self] }
        set { self[ComplicationPreviewTintKey.self] = newValue }
    }
}

/// One complication or Smart Stack widget. `snapshot == nil` is the "Start reading" placeholder.
struct ComplicationView: View {
    let snapshot: ReadingSnapshot?
    let family: WidgetFamily

    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.complicationPreviewTint) private var previewTint

    private var isRedacted: Bool { redactionReasons.contains(.privacy) }

    /// Brand colour in full colour; in tinted / vibrant modes the system colours the accentable parts.
    private var accent: Color {
        if let previewTint { return previewTint }
        guard renderingMode == .fullColor else { return .primary }
        return isLuminanceReduced ? Color.folitoAccent.opacity(0.6) : .folitoAccent
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(ComplicationText.accessibilityLabel(snapshot, redacted: isRedacted)))
            .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        guard family == .accessoryRectangular, !isRedacted, let chapter = snapshot?.chapterTitle,
              !chapter.isEmpty else { return Text(verbatim: "") }
        return Text(chapter)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryInline: inline
        default: rectangular
        }
    }

    // MARK: Circular: progress gauge, percentage in the centre, book symbol in the gap.

    @ViewBuilder private var circular: some View {
        if let snapshot {
            Gauge(value: snapshot.fraction) {
                Image(systemName: "book.fill")
            } currentValueLabel: {
                Text(ComplicationText.percent(snapshot.fraction))
                    .minimumScaleFactor(0.6)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(accent)
            .widgetAccentable()
        } else {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundStyle(accent)
                    .widgetAccentable()
            }
        }
    }

    // MARK: Corner: book symbol with a curved progress gauge along the bezel.

    private var corner: some View {
        Image(systemName: snapshot == nil ? "book.closed" : "book.fill")
            .font(.title3)
            .foregroundStyle(accent)
            .widgetAccentable()
            .widgetLabel {
                if let snapshot {
                    Gauge(value: snapshot.fraction) {
                        Text(ComplicationText.percent(snapshot.fraction))
                    } currentValueLabel: {
                        Text(ComplicationText.percent(snapshot.fraction))
                    }
                    .tint(accent)
                } else {
                    Text(ComplicationText.startReading)
                }
            }
    }

    // MARK: Inline: "45% · Title", shortening the title before dropping it.

    @ViewBuilder private var inline: some View {
        if let snapshot {
            if isRedacted {
                Text(ComplicationText.inline(snapshot, title: ""))
            } else {
                ViewThatFits {
                    Text(ComplicationText.inline(snapshot))
                    Text(ComplicationText.inline(snapshot, title: ComplicationText.shortTitle(snapshot.title)))
                    Text(ComplicationText.inline(snapshot, title: ""))
                }
            }
        } else {
            Text(ComplicationText.startReading)
        }
    }

    // MARK: Rectangular (also the Smart Stack): title, chapter, progress bar, time left in the chapter.

    @ViewBuilder private var rectangular: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "book.fill")
                        .font(.caption)
                        .foregroundStyle(accent)
                        .widgetAccentable()
                    Text(snapshot.title)
                        .font(.headline)
                        .lineLimit(1)
                        .privacySensitive()
                }
                if let chapter = snapshot.chapterTitle, !chapter.isEmpty {
                    Text(chapter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
                HStack(spacing: 6) {
                    Gauge(value: snapshot.fraction) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(accent)
                        .widgetAccentable()
                    Text(ComplicationText.percent(snapshot.fraction))
                        .font(.caption2.monospacedDigit())
                        .fixedSize()
                }
                if let minutes = snapshot.minutesLeft {
                    Text(ComplicationText.minutesLeft(minutes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "book.closed")
                        .font(.caption)
                        .foregroundStyle(accent)
                        .widgetAccentable()
                    Text(ComplicationText.appName)
                        .font(.headline)
                }
                Text(ComplicationText.startReading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
