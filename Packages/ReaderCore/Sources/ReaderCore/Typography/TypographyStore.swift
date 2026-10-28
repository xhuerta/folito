import Foundation

/// Persistence + migration + last-writer-wins merge for `ReaderTypography`, backed by `UserDefaults`
/// (the watch has no shared container; the phone keeps its own copy).
public struct TypographyStore {
    public static let key = "settings.typography"
    /// Pre-typography font size setting (a bare Double), migrated on first load.
    public static let legacyFontSizeKey = "settings.fontSize"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Current value. Order: stored JSON -> legacy font size (migrated and persisted) -> defaults.
    public func load() -> ReaderTypography {
        if let data = defaults.data(forKey: Self.key), let t = ReaderTypography.decode(data) { return t }
        var t = ReaderTypography.default
        if let legacy = defaults.object(forKey: Self.legacyFontSizeKey) as? Double {
            t.fontSize = legacy
            t = t.clamped()
            save(t)
            defaults.removeObject(forKey: Self.legacyFontSizeKey)
        }
        return t
    }

    public func save(_ t: ReaderTypography) {
        if let data = t.encoded() { defaults.set(data, forKey: Self.key) }
    }

    /// Resets to defaults. `now` becomes the stamp so the reset also wins over the other device's copy;
    /// nil removes the stored value entirely.
    public func reset(now: Int?) {
        defaults.removeObject(forKey: Self.legacyFontSizeKey)
        if let now {
            var t = ReaderTypography.default
            t.stamp = now
            save(t)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}

/// Wire format for typography over WatchConnectivity (see docs/WATCH_CONNECTIVITY.md). Values are
/// property-list types. Merged into the settings / library application contexts.
public enum TypographySync {
    public static let typographyKey = "typography"
    public static let stampKey = "typographyStamp"

    public static func context(for t: ReaderTypography) -> [String: Any] {
        guard let json = t.jsonString() else { return [:] }
        return [typographyKey: json, stampKey: t.stamp]
    }

    public static func decode(from info: [String: Any]) -> ReaderTypography? {
        guard let json = info[typographyKey] as? String, var t = ReaderTypography.decode(json: json) else { return nil }
        if let stamp = info[stampKey] as? Int { t.stamp = max(0, stamp) }
        return t
    }

    /// Stamp for a local edit: the clock, but always strictly newer than the value being replaced so two
    /// edits within the same second (or a skewed clock) still order correctly.
    public static func nextStamp(now: Int, after previous: Int) -> Int { max(now, previous + 1) }

    /// Last writer wins; a tie keeps the local copy (so resends are idempotent).
    public static func shouldApply(incoming: ReaderTypography, local: ReaderTypography) -> Bool {
        incoming.stamp > local.stamp
    }
}
