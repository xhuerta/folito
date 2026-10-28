import Foundation
import SwiftUI
import ReaderCore

/// Observable owner of the watch's `ReaderTypography`: persists it, stamps local edits and merges the
/// phone's copy (last writer wins by stamp).
@MainActor
final class TypographyModel: ObservableObject {
    @Published private(set) var value: ReaderTypography {
        didSet { style = ReaderRenderStyle(value) }
    }
    /// Fonts/colours resolved once per change; views read this instead of rebuilding fonts per render.
    @Published private(set) var style: ReaderRenderStyle

    private let store: TypographyStore
    private let clock: () -> Int
    /// Called after a local change so the watch can publish it to the phone.
    var onLocalChange: ((ReaderTypography) -> Void)?

    init(store: TypographyStore = TypographyStore(), clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.store = store
        self.clock = clock
        let loaded = store.load()
        self.value = loaded
        self.style = ReaderRenderStyle(loaded)
    }

    /// Applies a local edit. No-op when nothing visible changes.
    func update(_ mutate: (inout ReaderTypography) -> Void) {
        var t = value
        mutate(&t)
        t = t.clamped()
        guard !t.sameLook(as: value) else { return }
        commitLocal(t)
    }

    func apply(_ preset: ReaderTypography.Preset) {
        update { $0 = $0.applying(preset) }
    }

    /// Back to defaults. Always produces a newer stamp so the reset also reaches the phone.
    func reset() {
        var t = ReaderTypography.default
        t.stamp = value.stamp
        commitLocal(t)
    }

    private func commitLocal(_ t: ReaderTypography) {
        var t = t
        t.stamp = TypographySync.nextStamp(now: clock(), after: value.stamp)
        value = t
        store.save(t)
        onLocalChange?(t)
    }

    /// Merges the phone's copy. Returns true when it replaced ours.
    @discardableResult
    func applyRemote(_ remote: ReaderTypography) -> Bool {
        guard TypographySync.shouldApply(incoming: remote, local: value) else { return false }
        value = remote
        store.save(remote)
        return true
    }

    func binding<V>(_ keyPath: WritableKeyPath<ReaderTypography, V>) -> Binding<V> {
        Binding(get: { self.value[keyPath: keyPath] },
                set: { newValue in self.update { $0[keyPath: keyPath] = newValue } })
    }
}
