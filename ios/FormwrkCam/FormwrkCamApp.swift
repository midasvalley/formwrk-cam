import SwiftUI

@main
struct FormwrkCamApp: App {
    @StateObject private var camera = CaptureController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(camera: camera)
                .statusBarHidden()
                .preferredColorScheme(.dark)
                .onAppear { camera.start() }
                // Sliding the phone into a stand catches the side button often
                // enough that recovering from it has to be automatic.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { camera.resume() }
                }
        }
    }
}
