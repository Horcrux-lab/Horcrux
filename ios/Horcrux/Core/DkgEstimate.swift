import Foundation

/// Wall-clock estimates (in seconds) for MPC ceremonies on-device.
///
/// Derived from measured desktop benchmarks (see
/// `horcrux-core/tests/multi_party_ecdsa.rs`) plus the 5–10× slowdown from
/// disabled GMP assembly on iOS (Cargo.toml patch). The model:
///
///   DKG(secp256k1) ≈ C_prime  +  P · (n-1)
///     - C_prime: per-device Paillier safe-prime generation (baseline)
///     - P: per-peer ZK/Paillier verification
///
///   DKG(ed25519)  ≈ tiny constant + per-peer FROST round-trips (no Paillier)
///
///   Refresh(secp256k1) reuses the existing Paillier modulus, so C_prime is
///   replaced by the cheaper "rekey + ZK" baseline.
///
/// When the prime pool has ≥ n pregenerated pairs on hand, C_prime is paid
/// up-front in the background and the ceremony starts in seconds — we drop
/// the baseline accordingly.
///
/// The estimate is only consumed by UI (`CreateShardFlow.DkgProgressView`
/// and `RefreshShardSheet`) to drive the progress ring / remaining label.
/// Slightly generous is better than tight: users are happier finishing
/// "early" than seeing "Wrapping up…" flip on while work is still running.
enum DkgEstimate {
    /// DKG (full keygen + aux-info) estimate.
    /// - Parameters:
    ///   - curve: the ceremony curve (secp256k1 is CGGMP21, ed25519 is FROST).
    ///   - totalParties: `n` in an n-of-n or t-of-n ceremony (use the value
    ///     confirmed during peer handshake, not the user's input field).
    ///   - primePoolReady: true iff the pool is known to hold ≥ n pairs at
    ///     the moment the ceremony begins. Pool is queried from the FFI.
    static func dkgSeconds(
        curve: FfiCurveType,
        totalParties: Int,
        primePoolReady: Bool
    ) -> Int {
        let n = max(totalParties, 2)
        switch curve {
        case .ed25519:
            return 10 + 3 * (n - 1)
        default:
            let baseline = primePoolReady ? 30 : 120
            return baseline + 20 * (n - 2)
        }
    }

    /// Refresh estimate (CGGMP21 only).
    ///
    /// Desktop measured 3-of-3 refresh ≈ 19 s with fresh prime gen; on-device
    /// we're 5-6× slower, and pool-ready cuts the floor further because
    /// refresh re-uses the existing Paillier modulus rather than re-sampling.
    static func refreshSeconds(
        totalParties: Int,
        primePoolReady: Bool
    ) -> Int {
        let n = max(totalParties, 2)
        let baseline = primePoolReady ? 15 : 40
        return baseline + 10 * (n - 2)
    }

    /// Non-blocking prime-pool readiness check. Returns true iff the on-disk
    /// pool has at least `n` pre-generated pairs available.
    ///
    /// Implemented as a wrapper so callers don't have to know about the
    /// FFI surface.
    static func primePoolReady(for totalParties: Int) -> Bool {
        Int(horcruxPrimePoolCount()) >= max(totalParties, 2)
    }
}
