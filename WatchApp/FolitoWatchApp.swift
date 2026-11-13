import SwiftUI

@main
struct FolitoWatchApp: App {
    @StateObject private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(env)
                .environmentObject(env.library)
                .environmentObject(env.sync)
                .environmentObject(env.typography)
                .preferredColorScheme(.dark)
                // Complication taps (widgetURL): open the book at its position, or the library.
                .onOpenURL { env.handle(url: $0) }
                .task {
                    env.start()
                    // The complications and the Library show a newer synced position (#132).
                    env.refreshSyncedProgress()
                    // Foreground retry timer for progress that could not be pushed earlier.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                        if scenePhase == .active { env.sync.retryPending() }
                    }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        env.sync.configurationChanged()
                        env.library.reloadProgress()
                        env.refreshSyncedProgress()
                    } else if phase == .background {
                        env.scheduleBackgroundRefresh()
                    }
                }
        }
        // watchOS background refresh (a few per hour at most, as the system allows): one GET of the
        // complications' book while sync is on (#132).
        .backgroundTask(.appRefresh(SyncedProgressRefresher.taskID)) { [env = self.env] in
            await env.backgroundRefresh()
        }
    }
}
