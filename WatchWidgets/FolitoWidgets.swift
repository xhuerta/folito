import SwiftUI
import WidgetKit

/// Widget extension of the watch app: the Folito complications (circular, corner, inline, rectangular) and the
/// Smart Stack widget (rectangular). Reads the snapshot the watch app writes to the App Group; it never polls:
/// the app calls `WidgetCenter.reloadTimelines` when the reading position changes (`ComplicationPublisher`).
@main
struct FolitoWidgets: WidgetBundle {
    var body: some Widget {
        ReadingProgressWidget()
    }
}

struct ReadingProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationKind.readingProgress, provider: ReadingProgressProvider()) { entry in
            ReadingProgressEntryView(entry: entry)
        }
        .configurationDisplayName(Text("Reading Progress", comment: "Name of the Folito complication / widget in the watch face editor"))
        .description(Text("Your current book and how far you have read. Tap to keep reading.",
                          comment: "Description of the Folito complication / widget in the watch face editor"))
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct ReadingProgressEntry: TimelineEntry {
    let date: Date
    let snapshot: ReadingSnapshot?
    let relevance: TimelineEntryRelevance?
}

struct ReadingProgressProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReadingProgressEntry {
        ReadingProgressEntry(date: Date(), snapshot: .sample, relevance: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ReadingProgressEntry) -> Void) {
        let stored = ReadingSnapshotStore.shared.load()
        // The face editor / gallery shows the sample when nothing is being read yet.
        completion(ReadingProgressEntry(date: Date(), snapshot: stored ?? (context.isPreview ? .sample : nil),
                                        relevance: nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadingProgressEntry>) -> Void) {
        let snapshot = ReadingSnapshotStore.shared.load()
        let entries = SmartStackRelevance.entries(for: snapshot, now: Date()).map {
            ReadingProgressEntry(date: $0.date, snapshot: snapshot, relevance: $0.relevance)
        }
        // No polling: the watch app reloads the timeline whenever the snapshot changes.
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct ReadingProgressEntryView: View {
    let entry: ReadingProgressEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ComplicationView(snapshot: entry.snapshot, family: family)
            .widgetURL(FolitoDeepLink.forSnapshot(entry.snapshot).url)
            // Shown in the Smart Stack only; watch faces drop the container background.
            .containerBackground(for: .widget) {
                LinearGradient(colors: [Color.folitoAccent.opacity(0.35), Color.folitoAccent.opacity(0.12)],
                               startPoint: .top, endPoint: .bottom)
            }
    }
}
