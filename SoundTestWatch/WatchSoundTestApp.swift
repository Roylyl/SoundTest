import SwiftUI

@main
struct WatchSoundTestApp: App {
    @StateObject private var sound = WatchSoundController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(sound)
        }
        .onChange(of: scenePhase) { _, phase in
            sound.setSceneActive(phase == .active)
        }
    }
}
