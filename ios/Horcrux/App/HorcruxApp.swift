import SwiftUI

@main
struct HorcruxApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var deepLinkRouter = DeepLinkRouter.shared
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
                .environmentObject(deepLinkRouter)
                .blur(radius: blurRadius)
                .animation(.easeInOut(duration: 0.15), value: blurRadius)
                .accessibilityElement(children: blurRadius > 0 ? .ignore : .contain)
                .accessibilityLabel(blurRadius > 0 ? "App content hidden for privacy" : "")
                .onOpenURL { url in
                    if let link = deepLinkRouter.parseURL(url) {
                        deepLinkRouter.handle(link)
                    }
                }
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
                        // Start confirmation poller + broadcast pending queue
                        if appState.isUnlocked {
                            Task {
                                await appState.confirmationPoller.start(
                                    store: appState.transactionStore,
                                    service: appState.blockchainService,
                                    config: appState.networkConfig
                                )
                                await appState.pendingBroadcastQueue.broadcastAll(
                                    service: appState.blockchainService,
                                    config: appState.networkConfig,
                                    transactionStore: appState.transactionStore
                                )
                            }
                        }
                        // Periodic debugger check on foreground
                        if AntiDebug.performChecks() {
                            showDebuggerWarning = true
                        }
                        // Auto-expire stale ceremony sessions (10 min TTL)
                        Task {
                            await appState.ceremonyState.cleanupStale()
                        }
                    }
                }
                .task {
                    // Request notification permission on first launch
                    await NotificationManager.shared.requestAuthorization()
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
