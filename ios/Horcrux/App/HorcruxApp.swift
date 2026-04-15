import SwiftUI

@main
struct HorcruxApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var blurRadius: CGFloat = 0

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .blur(radius: blurRadius)
                .animation(.easeInOut(duration: 0.15), value: blurRadius)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    // Blur content in app-switcher to hide sensitive data
                    blurRadius = 30
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    blurRadius = 0
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                    // Notify user that screenshot was detected
                    NotificationCenter.default.post(name: .horcruxScreenshotDetected, object: nil)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        appState.onEnterBackground()
                    } else if newPhase == .active {
                        appState.checkAutoLock()
                    }
                }
        }
    }
}

extension Notification.Name {
    static let horcruxScreenshotDetected = Notification.Name("horcruxScreenshotDetected")
}
