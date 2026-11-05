import Foundation

/// The reader's speed, learned on the device (`ReadingSpeedLearner`) and stored only there (`ReadingSpeedStore`).
public struct ReadingSpeed: Codable, Sendable, Equatable {
    /// Words per minute for space-separated text.
    public var wordsPerMinute: Double
    /// Characters per minute for Chinese and Japanese text (`TextLength.cjkCharacters`).
    public var charactersPerMinute: Double

    /// A typical adult reading speed: about 200 words or 500 CJK characters per minute.
    public static let defaultWordsPerMinute: Double = 200
    public static let defaultCharactersPerMinute: Double = 500
    public static let `default` = ReadingSpeed(wordsPerMinute: defaultWordsPerMinute,
                                               charactersPerMinute: defaultCharactersPerMinute)

    public static let wordsPerMinuteRange: ClosedRange<Double> = 50...1_000
    public static let charactersPerMinuteRange: ClosedRange<Double> = 100...2_500

    public init(wordsPerMinute: Double, charactersPerMinute: Double) {
        self.wordsPerMinute = Self.clamp(wordsPerMinute, to: Self.wordsPerMinuteRange,
                                         fallback: Self.defaultWordsPerMinute)
        self.charactersPerMinute = Self.clamp(charactersPerMinute, to: Self.charactersPerMinuteRange,
                                              fallback: Self.defaultCharactersPerMinute)
    }

    /// Estimated reading time of `length`, in seconds.
    public func seconds(for length: TextLength) -> TimeInterval {
        Double(length.words) / wordsPerMinute * 60 + Double(length.cjkCharacters) / charactersPerMinute * 60
    }

    // Decoding goes through init so a corrupt stored value is clamped as well.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(wordsPerMinute: try c.decode(Double.self, forKey: .wordsPerMinute),
                  charactersPerMinute: try c.decode(Double.self, forKey: .charactersPerMinute))
    }

    private static func clamp(_ v: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard v.isFinite else { return fallback }
        return min(max(v, range.lowerBound), range.upperBound)
    }
}

/// Learns `ReadingSpeed` from the time actually spent on each page, with an exponential moving average.
///
/// The watch reader scrolls instead of turning pages, so a "page" is a stretch of at least `pageWords` words
/// (or the CJK equivalent) read in one go. Pages read faster than `minimumPageSeconds` are skimming or
/// scrolling past; pages that took longer than `maximumPageSeconds` include a pause (wrist down, interrupted).
/// Both are ignored, so they never move the estimate, and so is a page whose speed is outside
/// `ReadingSpeed.wordsPerMinuteRange` (or the CJK range).
public struct ReadingSpeedLearner: Sendable, Equatable {
    public var minimumPageSeconds: TimeInterval
    public var maximumPageSeconds: TimeInterval
    /// Weight of a new page in the moving average (0...1).
    public var smoothing: Double
    /// Words that make a page; CJK characters count as `wordsPerCJKCharacter` words each.
    public var pageWords: Double

    public static let standard = ReadingSpeedLearner()

    public init(minimumPageSeconds: TimeInterval = 2, maximumPageSeconds: TimeInterval = 5 * 60,
                smoothing: Double = 0.2, pageWords: Double = 50) {
        self.minimumPageSeconds = minimumPageSeconds
        self.maximumPageSeconds = maximumPageSeconds
        self.smoothing = min(max(smoothing, 0), 1)
        self.pageWords = pageWords
    }

    /// Size of `length` in "word equivalents", using the ratio of the default speeds (2.5 characters per word).
    public static func wordEquivalents(_ length: TextLength) -> Double {
        Double(length.words) + Double(length.cjkCharacters)
            * ReadingSpeed.defaultWordsPerMinute / ReadingSpeed.defaultCharactersPerMinute
    }

    /// True when a page of `seconds` is a usable sample (neither skimmed nor interrupted).
    public func accepts(seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= minimumPageSeconds && seconds <= maximumPageSeconds
    }

    /// `speed` updated with one page of `length` read in `seconds`, or nil when the page is an outlier.
    /// The speed of the script that dominates the page (words or CJK characters) is updated; the other is kept.
    public func updated(_ speed: ReadingSpeed, page length: TextLength, seconds: TimeInterval) -> ReadingSpeed? {
        guard accepts(seconds: seconds), !length.isEmpty else { return nil }
        let wordSeconds = Double(length.words) / speed.wordsPerMinute * 60
        let cjkSeconds = Double(length.cjkCharacters) / speed.charactersPerMinute * 60
        let predicted = wordSeconds + cjkSeconds
        guard predicted > 0 else { return nil }
        // Observed / predicted pace, applied to the dominant script's speed.
        let factor = predicted / seconds
        var result = speed
        if wordSeconds >= cjkSeconds {
            let observed = speed.wordsPerMinute * factor
            // Faster or slower than anyone reads: a fling of the crown, or the page sat on screen unread.
            guard ReadingSpeed.wordsPerMinuteRange.contains(observed) else { return nil }
            result.wordsPerMinute = speed.wordsPerMinute + smoothing * (observed - speed.wordsPerMinute)
        } else {
            let observed = speed.charactersPerMinute * factor
            guard ReadingSpeed.charactersPerMinuteRange.contains(observed) else { return nil }
            result.charactersPerMinute = speed.charactersPerMinute + smoothing * (observed - speed.charactersPerMinute)
        }
        // Through init, which clamps.
        return ReadingSpeed(wordsPerMinute: result.wordsPerMinute, charactersPerMinute: result.charactersPerMinute)
    }
}

/// Groups the text the reader scrolls past into pages and times them for `ReadingSpeedLearner`.
/// Pure value type: the caller passes the clock.
public struct PageTimer: Sendable, Equatable {
    public private(set) var pageStart: Date
    public private(set) var accumulated: TextLength = .zero
    public let learner: ReadingSpeedLearner

    public init(start: Date, learner: ReadingSpeedLearner = .standard) {
        self.pageStart = start
        self.learner = learner
    }

    /// Starts a new page without a sample: after a jump, going back, or an interruption (menu, lookup).
    public mutating func reset(at date: Date) {
        pageStart = date
        accumulated = .zero
    }

    /// The reader moved forward past `length` of text at `date`. When that completes a page, returns the
    /// page (length and seconds) and starts the next one. Outliers are returned too; `learner` filters them.
    public mutating func advance(by length: TextLength, at date: Date) -> (length: TextLength, seconds: TimeInterval)? {
        accumulated = accumulated + length
        guard ReadingSpeedLearner.wordEquivalents(accumulated) >= learner.pageWords else { return nil }
        let page = (length: accumulated, seconds: date.timeIntervalSince(pageStart))
        reset(at: date)
        return page
    }

    /// Convenience: advances and, for an accepted page, returns the updated speed.
    public mutating func advance(by length: TextLength, at date: Date, speed: ReadingSpeed) -> ReadingSpeed? {
        guard let page = advance(by: length, at: date) else { return nil }
        return learner.updated(speed, page: page.length, seconds: page.seconds)
    }
}

/// On-device storage of the learned speed (UserDefaults; never sent anywhere).
public final class ReadingSpeedStore: @unchecked Sendable {
    public static let key = "reading.speed"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> ReadingSpeed {
        guard let data = defaults.data(forKey: Self.key),
              let speed = try? JSONDecoder().decode(ReadingSpeed.self, from: data) else { return .default }
        return speed
    }

    public func save(_ speed: ReadingSpeed) {
        if let data = try? JSONEncoder().encode(speed) { defaults.set(data, forKey: Self.key) }
    }

    /// Forgets the learned speed (back to `ReadingSpeed.default`).
    public func reset() { defaults.removeObject(forKey: Self.key) }
}
