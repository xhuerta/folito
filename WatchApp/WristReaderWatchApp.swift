import SwiftUI

@main
struct WristReaderWatchApp: App {
    @StateObject private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(env)
                .environmentObject(env.library)
                .environmentObject(env.sync)
                .preferredColorScheme(.dark)
                .task {
                    env.start()
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
                    }
                }
        }
    }
}
