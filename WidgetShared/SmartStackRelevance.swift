import Foundation
import WidgetKit

enum ComplicationKind {
    /// Widget kind of the reading-progress complication (WatchWidgets/FolitoWidgets.swift).
    static let readingProgress = "FolitoReadingProgress"
}

/// Smart Stack relevance: a book read in the last few hours ranks higher, then falls back to a low score.
/// Expressed as two timeline entries (now, and when the recent window ends), so no reload is needed.
enum SmartStackRelevance {
    static let recentWindow: TimeInterval = 6 * 60 * 60
    static let recentScore: Float = 50
    static let idleScore: Float = 5

    struct Point {
        let date: Date
        let relevance: TimelineEntryRelevance?
    }

    static func entries(for snapshot: ReadingSnapshot?, now: Date) -> [Point] {
        guard let snapshot else {
            return [Point(date: now, relevance: TimelineEntryRelevance(score: 0))]
        }
        let end = snapshot.updatedAt.addingTimeInterval(recentWindow)
        guard end > now else {
            return [Point(date: now, relevance: TimelineEntryRelevance(score: idleScore))]
        }
        return [Point(date: now, relevance: TimelineEntryRelevance(score: recentScore, duration: end.timeIntervalSince(now))),
                Point(date: end, relevance: TimelineEntryRelevance(score: idleScore))]
    }
}
