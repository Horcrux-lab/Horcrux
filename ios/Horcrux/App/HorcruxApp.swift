import SwiftUI

@main
struct HorcruxApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var blurRadius: CGFloat = 0
    @State private var showDebuggerWarning = false

    init() {
        // Anti-debug: deny attachment + detect (release builds only)
        AntiDebug.denyDebuggerAttach()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .blur(radius: blurRadius)
                .animation(.easeInOut(duration: 0.15), value: blurRadius)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    blurRadius = 30
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    blurRadius = 0
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                    NotificationCenter.default.post(name: .horcruxScreenshotDetected, object: nil)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        appState.onEnterBackground()
                    } else if newPhase == .active {
                        appState.checkAutoLock()
                        // Periodic debugger check on foreground
                        if AntiDebug.performChecks() {
                            showDebuggerWarning = true
                        }
                    }
                }
                .alert("Security Violation", isPresented: $showDebuggerWarning) {
                    Button("Exit App", role: .destructive) {
                        exit(0)
                    }
                } message: {
                    Text("A debugger or instrumentation tool has been detected. The app cannot run in this environment to protect your key shards.")
                }
        }
    }
}

extension Notification.Name {
    static let horcruxScreenshotDetected = Notification.Name("horcruxScreenshotDetected")
}
