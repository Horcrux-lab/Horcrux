import Foundation
import UIKit

/// Background manager for the Paillier prime pool.
///
/// DKG / key_refresh needs two 512-bit safe primes per participant. On iOS,
/// GMP's assembly is disabled (for Mach-O ABI reasons) so each pair takes
/// 30–120s to generate. To avoid blocking the user, we pre-generate pairs
/// in the background and cache them on disk; the creation flow pops one
/// in milliseconds.
///
/// Storage: `Library/Caches/prime_pool/`. iOS gives this dir
/// `NSFileProtectionCompleteUntilFirstUserAuthentication` by default, which
/// keeps the primes encrypted at rest while the device is locked.
///
/// Policy:
/// - Keep at most `targetCount` pairs in the pool.
/// - Refill on `didBecomeActive` from a `.background` priority task.
/// - Each pair is deleted on use (`horcruxPrimePoolGenerateOne` is not
///   idempotent; `try_take` inside the core deletes the file it hands out).
@MainActor
final class PrimePoolManager: ObservableObject {
    static let shared = PrimePoolManager()

    /// How many pairs we try to keep stocked. 1 is enough to make "second
    /// wallet creation" feel instant without burning battery.
    private let targetCount: UInt32 = 2

    @Published private(set) var count: UInt32 = 0
    @Published private(set) var isGenerating: Bool = false

    private var refillTask: Task<Void, Never>?
    private var didInit = false

    private init() {}

    /// Install the pool directory. Idempotent. Safe to call from the main
    /// thread at app init — filesystem setup is lightweight; the slow
    /// generation runs later from `refillIfNeeded()`.
    func configure() {
        guard !didInit else { return }
        didInit = true

        let dir = Self.poolDirectory()
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        do {
            try horcruxPrimePoolInit(dir: dir.path)
            self.count = horcruxPrimePoolCount()
            print("[PrimePool] configured dir=\(dir.path) count=\(self.count)")
        } catch {
            print("[PrimePool] init failed: \(error)")
            return
        }

        // Kick off the first refill as soon as we're configured; don't wait
        // for the next didBecomeActive (which may already have fired).
        refillIfNeeded()
    }

    /// Kick a background refill if the pool is under target. Safe to call
    /// repeatedly — duplicate calls collapse onto the existing task.
    func refillIfNeeded() {
        guard didInit else { return }
        guard refillTask == nil else { return }
        let current = horcruxPrimePoolCount()
        self.count = current
        guard current < targetCount else { return }

        let needed = Int(targetCount - current)
        isGenerating = true
        print("[PrimePool] refilling \(needed) pair(s) (have \(current)/\(targetCount))")
        refillTask = Task.detached(priority: .utility) { [weak self] in
            for i in 0..<needed {
                // Abort if app goes to background mid-generation; we'll
                // resume on next didBecomeActive.
                if Task.isCancelled { break }
                let t0 = Date()
                do {
                    try horcruxPrimePoolGenerateOne()
                    let dt = Date().timeIntervalSince(t0)
                    print(String(format: "[PrimePool] generated pair %d/%d in %.1fs", i + 1, needed, dt))
                } catch {
                    print("[PrimePool] generate failed: \(error)")
                    break
                }
            }
            await MainActor.run { [weak self] in
                self?.count = horcruxPrimePoolCount()
                self?.isGenerating = false
                self?.refillTask = nil
            }
        }
    }

    /// Called when the app goes to background — cancel in-flight generation
    /// so iOS doesn't kill us for CPU usage.
    func suspend() {
        refillTask?.cancel()
        refillTask = nil
    }

    private static func poolDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("prime_pool", isDirectory: true)
    }
}
