import SwiftUI

// TEMPORARY (branch fix/ax-elementless): switches that remove one suspect at a time, so the accessibility
// audit's element-less findings can be bisected in CI. Launch argument `-AXProbe <variant>`. Debug only.
enum AXProbe {
    static func on(_ variant: String) -> Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "AXProbe") == variant
        #else
        return false
        #endif
    }
}

extension View {
    @ViewBuilder
    func probeChrome() -> some View {
        if AXProbe.on("noTabBar") {
            toolbar(.hidden, for: .tabBar)
        } else if AXProbe.on("noTitle") {
            toolbar(.hidden, for: .navigationBar)
        } else if AXProbe.on("inlineTitle") {
            navigationBarTitleDisplayMode(.inline)
        } else {
            self
        }
    }
}
