import SwiftUI

@main
struct SoundTestApp: App {
    @StateObject private var controller = SoundController()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(controller) }
        .onChange(of: phase) { _, next in
            if next == .background { controller.stop(reason: "应用进入后台，本轮停止。") }
            if next == .active { controller.refreshInputs(); controller.reloadHistory() }
        }
    }
}
