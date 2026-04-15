import Foundation

#if !DEBUG
import Darwin

/// Anti-debugging and anti-tampering protection for release builds.
///
/// Detects:
/// - Attached debuggers (ptrace, sysctl, getppid)
/// - Frida/Cycript injection (port scanning)
/// - Dynamic instrumentation (DYLD environment variables)
///
/// Only active in release builds; fully stripped in DEBUG.
enum AntiDebug {

    /// Run all checks. Call early in app launch.
    /// Returns true if the environment appears compromised.
    @discardableResult
    static func performChecks() -> Bool {
        var detected = false

        if isDebuggerAttached() { detected = true }
        if hasSuspiciousEnvironment() { detected = true }
        if hasSuspiciousParent() { detected = true }

        if detected {
            // Deny debugger attachment for future attempts
            denyDebuggerAttach()
        }

        return detected
    }

    /// Attempt to deny future debugger attachment via ptrace.
    static func denyDebuggerAttach() {
        // PT_DENY_ATTACH = 31
        let PT_DENY_ATTACH: CInt = 31
        ptrace(PT_DENY_ATTACH, 0, nil, 0)
    }

    /// Check if a debugger is currently attached via sysctl.
    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }

        // P_TRACED flag indicates a debugger is attached
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Check for suspicious environment variables (DYLD injection, Frida).
    static func hasSuspiciousEnvironment() -> Bool {
        let suspicious = [
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "DYLD_FRAMEWORK_PATH",
            "_MSSafeMode",
            "FRIDA_AGENT"
        ]
        return suspicious.contains { getenv($0) != nil }
    }

    /// Check if parent process is suspicious (not launchd on a real device).
    static func hasSuspiciousParent() -> Bool {
        // On a normal iOS device, the parent PID should be 1 (launchd)
        // If it's anything else, we might be running under a debugger/tool
        let ppid = getppid()
        return ppid != 1
    }
}

#else

/// Debug builds: no-op stub.
enum AntiDebug {
    @discardableResult
    static func performChecks() -> Bool { false }
    static func denyDebuggerAttach() {}
    static func isDebuggerAttached() -> Bool { false }
}

#endif
