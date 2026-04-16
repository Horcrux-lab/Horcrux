import Foundation
import MachO
import UIKit

/// Basic jailbreak and environment tampering detection.
/// Not bulletproof (sophisticated jailbreaks can bypass), but raises the bar.
enum SecurityEnvironment {

    struct CheckResult {
        let isCompromised: Bool
        let reasons: [String]
    }

    /// Run all checks and return a combined result.
    static func check() -> CheckResult {
        // Skip jailbreak checks on simulator (always triggers false positives)
        #if targetEnvironment(simulator)
        return CheckResult(isCompromised: false, reasons: [])
        #else
        var reasons: [String] = []

        if checkJailbreakPaths() { reasons.append("Jailbreak artifacts detected") }
        if checkWritableSystem() { reasons.append("System partition is writable") }
        if checkSuspiciousURLSchemes() { reasons.append("Suspicious URL schemes available") }
        if checkDylibs() { reasons.append("Suspicious dynamic libraries loaded") }
        if checkForkable() { reasons.append("Process can fork (not sandboxed)") }

        return CheckResult(isCompromised: !reasons.isEmpty, reasons: reasons)
        #endif
    }

    /// Quick check — returns true if device appears jailbroken.
    /// Use to gate sensitive operations like DKG and signing.
    static var isCompromised: Bool {
        check().isCompromised
    }

    // MARK: - Checks

    private static let jailbreakPaths = [
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/usr/sbin/sshd",
        "/usr/bin/ssh",
        "/etc/apt",
        "/private/var/lib/apt",
        "/private/var/lib/cydia",
        "/private/var/stash",
        "/usr/libexec/cydia",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/var/cache/apt",
        "/var/lib/dpkg",
        "/bin/bash",
        "/bin/sh"
    ]

    private static func checkJailbreakPaths() -> Bool {
        jailbreakPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private static func checkWritableSystem() -> Bool {
        let testPath = "/private/jailbreak_test_\(UUID().uuidString)"
        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: testPath)
            return true
        } catch {
            return false
        }
    }

    private static func checkSuspiciousURLSchemes() -> Bool {
        let schemes = ["cydia://", "sileo://", "zbra://", "filza://"]
        return schemes.contains { scheme in
            if let url = URL(string: scheme) {
                return UIApplication.shared.canOpenURL(url)
            }
            return false
        }
    }

    private static func checkDylibs() -> Bool {
        let suspiciousLibs = [
            "MobileSubstrate",
            "SubstrateLoader",
            "TweakInject",
            "libhooker",
            "substitute"
        ]
        let count = _dyld_image_count()
        for i in 0..<count {
            if let name = _dyld_get_image_name(i) {
                let path = String(cString: name)
                if suspiciousLibs.contains(where: { path.contains($0) }) {
                    return true
                }
            }
        }
        return false
    }

    private static func checkForkable() -> Bool {
        // fork() is unavailable on iOS simulator; use posix_spawn check instead
        var pid: pid_t = 0
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/true"), nil]
        let result = posix_spawn(&pid, "/bin/true", &fileActions, nil, argv, nil)
        argv.compactMap { $0 }.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fileActions)
        if result == 0 {
            var stat: Int32 = 0
            waitpid(pid, &stat, 0)
            return true
        }
        return false
    }
}
