import SwiftUI
import BackgroundTasks

@main
struct HorcruxApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var deepLinkRouter = DeepLinkRouter.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var blurRadius: CGFloat = 0
    @State private var showDebuggerWarning = false

    static let broadcastRetryTaskIdentifier = "com.horcrux.broadcast-retry"

    init() {
        // Reset state for E2E tests
        if ProcessInfo.processInfo.arguments.contains("-UITestingResetState") {
            let domain = Bundle.main.bundleIdentifier ?? "com.horcrux.wallet"
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
            try? KeychainManager.shared.delete(key: "com.horcrux.pin_hash")
            try? KeychainManager.shared.delete(key: "horcrux_relay_url")
            // Clear persisted wallet data
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: docs.appendingPathComponent("horcrux_wallets.json"))
                try? FileManager.default.removeItem(at: docs.appendingPathComponent("horcrux_transactions.json"))
            }
        }

        // Register default preferences so keys read via UserDefaults.bool(forKey:)
        // match the @AppStorage defaults declared in SettingsView before the user
        // visits Settings. Without this, biometric unlock stays hidden on first
        // launch because the raw key is never written.
        UserDefaults.standard.register(defaults: [
            "biometricEnabled": true
        ])

        // Anti-debug: deny attachment + detect (release builds only)
        AntiDebug.denyDebuggerAttach()

        // Install Paillier prime pool directory and start background
        // pre-generation. Filesystem setup is synchronous + cheap; the actual
        // prime generation happens on a utility-priority task from
        // `refillIfNeeded()`.
        PrimePoolManager.shared.configure()

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.broadcastRetryTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await HorcruxApp.handleBroadcastRetry(task: processingTask)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environmentObject(appState)
                .environmentObject(appState.walletStore)
                .environmentObject(deepLinkRouter)
                .blur(radius: blurRadius)
                .animation(.easeInOut(duration: 0.15), value: blurRadius)
                .accessibilityElement(children: blurRadius > 0 ? .ignore : .contain)
                .accessibilityLabel(blurRadius > 0 ? L10n.App.contentHidden : "")
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
                    PrimePoolManager.shared.refillIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                    NotificationCenter.default.post(name: .horcruxScreenshotDetected, object: nil)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        appState.onEnterBackground()
                        PrimePoolManager.shared.suspend()
                        Self.scheduleBroadcastRetry()
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
                        if !ProcessInfo.processInfo.arguments.contains("-UITesting"),
                           AntiDebug.performChecks() {
                            showDebuggerWarning = true
                        }
                        // Auto-expire stale ceremony sessions (10 min TTL)
                        Task {
                            await appState.ceremonyState.cleanupStale()
                        }
                    }
                }
                .task {
                    #if targetEnvironment(simulator)
                    // Skip notification permission on simulator
                    #else
                    guard !ProcessInfo.processInfo.arguments.contains("-UITesting") else { return }
                    guard !appState.isFirstLaunch else { return }
                    await NotificationManager.shared.requestAuthorization()
                    #endif
                }
                .alert(L10n.App.securityViolation, isPresented: $showDebuggerWarning) {
                    Button(L10n.App.exitApp, role: .destructive) {
                        exit(0)
                    }
                } message: {
                    Text(L10n.App.debuggerDetected)
                }
        }
    }
}

// MARK: - Background Broadcast Retry

extension HorcruxApp {
    static func scheduleBroadcastRetry() {
        let request = BGProcessingTaskRequest(identifier: broadcastRetryTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            SecureLog.warning("Failed to schedule broadcast retry: \(error.localizedDescription)")
        }
    }

    @MainActor
    static func handleBroadcastRetry(task: BGProcessingTask) async {
        let appState = AppState.shared
        let queue = appState.pendingBroadcastQueue

        task.expirationHandler = {
            SecureLog.warning("Broadcast retry task expired before completion")
        }

        guard !queue.pending.isEmpty else {
            task.setTaskCompleted(success: true)
            scheduleBroadcastRetry()
            return
        }

        await queue.broadcastAll(
            service: appState.blockchainService,
            config: appState.networkConfig,
            transactionStore: appState.transactionStore
        )

        let allSucceeded = queue.pending.isEmpty
        task.setTaskCompleted(success: allSucceeded)
        scheduleBroadcastRetry()
    }
}

extension Notification.Name {
    static let horcruxScreenshotDetected = Notification.Name("horcruxScreenshotDetected")
}
