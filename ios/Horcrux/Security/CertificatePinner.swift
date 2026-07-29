import Foundation
import Security
import CryptoKit

/// TLS certificate pinning via SPKI (Subject Public Key Info) hash comparison.
///
/// Strategy:
/// - **Default RPC endpoints**: pinned to known public key hashes
/// - **User-configured endpoints**: Trust-On-First-Use (TOFU) — pin the hash on
///   first successful connection, reject if it changes later
/// - **Pinning failures**: connection is rejected, user is warned
///
/// Uses SHA-256 hash of the DER-encoded SPKI, matching the format used by
/// Chrome HPKP and similar systems.
final class CertificatePinner: NSObject, @unchecked Sendable {
    static let shared = CertificatePinner()

    /// Known SPKI hashes for default RPC endpoints (base64-encoded SHA-256).
    /// These are the public key pins for the default node providers.
    /// When providers rotate certs (but keep the same key), pins remain valid.
    private var pinnedHashes: [String: Set<String>] = [:]

    /// Hosts whose pins were registered via `registerKnownPins()` at init.
    /// These are frozen — on SPKI mismatch we HARD-FAIL rather than re-pin
    /// (audit H4: silently rotating known pins defeats the entire point of
    /// pinning, because an attacker presenting any CA-issued cert for the
    /// host would just cause us to trust their key). Only TOFU hosts
    /// (user-configured endpoints) are allowed to auto-rotate with a
    /// warning on the assumption that the user chose the endpoint, so a
    /// cert rotation is far more likely than an MITM targeting that
    /// specific user-chosen URL.
    private var knownHosts: Set<String> = []

    /// TOFU-stored hashes for user-configured endpoints.
    private let tofuKey = "com.horcrux.cert_pins_tofu"

    private override init() {
        super.init()
        loadTOFUPins()
        registerKnownPins()
    }

    // MARK: - Pin Management

    /// Add a known pin for a host.
    func addPin(host: String, spkiHashBase64: String) {
        if pinnedHashes[host] == nil {
            pinnedHashes[host] = []
        }
        pinnedHashes[host]?.insert(spkiHashBase64)
    }

    /// Remove all pins for a host (e.g., when user changes RPC URL).
    func removePins(for host: String) {
        pinnedHashes.removeValue(forKey: host)
        saveTOFUPins()
    }

    /// Check whether a host has any pins (known or TOFU).
    func hasPins(for host: String) -> Bool {
        guard let pins = pinnedHashes[host] else { return false }
        return !pins.isEmpty
    }

    // MARK: - Validation

    /// Validate a server trust against pinned SPKI hashes.
    /// Returns `true` if the certificate chain contains a matching pin.
    func validate(serverTrust: SecTrust, host: String) -> Bool {
        let certCount = SecTrustGetCertificateCount(serverTrust)
        guard certCount > 0 else { return false }

        // Extract SPKI hashes from all certificates in the chain
        var serverHashes: Set<String> = []
        if let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] {
            for cert in chain {
                if let hash = spkiHash(of: cert) {
                    serverHashes.insert(hash)
                }
            }
        }

        guard !serverHashes.isEmpty else { return false }

        // Check against known pins. Known-pinned hosts MUST match —
        // silent re-pinning on these would defeat the pinning guarantee
        // (audit H4). TOFU hosts (user-configured endpoints) are allowed
        // to rotate with a warning because the user explicitly chose the
        // URL, making cert rotation far more plausible than a targeted
        // MITM.
        if let knownPins = pinnedHashes[host], !knownPins.isEmpty {
            if !knownPins.isDisjoint(with: serverHashes) {
                return true
            }
            if knownHosts.contains(host) {
                SecureLog.error("SPKI pin mismatch for known host \(host) — connection rejected (possible MITM or unannounced cert rotation)")
                return false
            }
            SecureLog.warning("SPKI pin rotation for TOFU host \(host): stored hashes disjoint from current chain, re-pinning")
            pinnedHashes[host] = serverHashes
            saveTOFUPins()
            return true
        }

        // TOFU: no pins yet → trust and store the leaf hash
        if serverHashes.first != nil {
            pinnedHashes[host] = serverHashes
            saveTOFUPins()
        }
        return true
    }

    // MARK: - SPKI Hash Extraction

    /// Compute the SHA-256 hash of a certificate's Subject Public Key Info.
    /// Returns base64-encoded hash string.
    func spkiHash(of certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }

        // The external representation is the raw key data.
        // For proper SPKI hashing we need the DER-encoded SubjectPublicKeyInfo.
        // For EC keys, we wrap with the standard ASN.1 header.
        let spkiData = wrapInSPKI(publicKeyData, keyType: publicKey)
        let hash = SHA256.hash(data: spkiData)
        return Data(hash).base64EncodedString()
    }

    /// Wrap raw public key bytes in an ASN.1 SubjectPublicKeyInfo structure.
    private func wrapInSPKI(_ keyData: Data, keyType: SecKey) -> Data {
        // Determine key type from attributes
        guard let attributes = SecKeyCopyAttributes(keyType) as? [String: Any],
              let type = attributes[kSecAttrKeyType as String] as? String else {
            return keyData
        }

        if type == (kSecAttrKeyTypeRSA as String) {
            // RSA SPKI header (for 2048-bit keys)
            let rsaHeader: [UInt8] = [
                0x30, 0x82, 0x01, 0x22, // SEQUENCE (290 bytes)
                0x30, 0x0D,             // SEQUENCE (13 bytes) - AlgorithmIdentifier
                0x06, 0x09,             // OID (9 bytes)
                0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, // rsaEncryption
                0x05, 0x00,             // NULL
                0x03, 0x82, 0x01, 0x0F, // BIT STRING
                0x00                    // padding
            ]
            return Data(rsaHeader) + keyData
        } else if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            // EC P-256 SPKI header
            let ecHeader: [UInt8] = [
                0x30, 0x59,             // SEQUENCE (89 bytes)
                0x30, 0x13,             // SEQUENCE (19 bytes) - AlgorithmIdentifier
                0x06, 0x07,             // OID (7 bytes)
                0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // ecPublicKey
                0x06, 0x08,             // OID (8 bytes)
                0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // prime256v1
                0x03, 0x42, 0x00        // BIT STRING (66 bytes)
            ]
            return Data(ecHeader) + keyData
        }

        // Unknown key type — hash the raw key data
        return keyData
    }

    // MARK: - Known Pin Registration

    /// Pre-pin known RPC endpoint certificates.
    /// These are SPKI SHA-256 hashes (base64) for the TLS certificates of default endpoints.
    /// Multiple pins per host provide backup when certificates rotate.
    ///
    /// Dual-pinning strategy (audit H4):
    /// - **Current pins**: SPKI hashes currently presented by the provider.
    /// - **Backup pins**: SPKI hashes the provider has committed to rotating
    ///   to *next*. Generated out-of-band (provider publishes next-gen pin
    ///   before rotating), added here ahead of rotation, promoted to current
    ///   on the release that follows rotation day. Without pre-staged backup
    ///   pins, a CA rotation bricks the feature for every user on the old
    ///   binary — which is why audit H4 explicitly calls for both slots.
    ///
    /// Operational process for adding a backup pin:
    /// 1. Obtain the new SPKI hash from the provider (or compute it yourself
    ///    from `openssl s_client -showcerts -servername $HOST -connect $HOST:443`
    ///    → `openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER
    ///       | openssl dgst -sha256 -binary | base64`).
    /// 2. Add it to the host's set below with a comment noting "backup —
    ///    rotation planned YYYY-MM-DD".
    /// 3. Ship the release.
    /// 4. After rotation day, remove the old pin in the next release.
    private func registerKnownPins() {
        // List of known hosts, frozen separately so we don't accidentally
        // treat TOFU-loaded entries (merged in by `loadTOFUPins` earlier
        // in init) as known pins.
        let known: [String: Set<String>] = [
            // PublicNode — the default Ethereum mainnet endpoint
            // (`EVMNetwork.mainnet.publicDefaultRPC`). Chain as served on
            // 2026-07-29: leaf CN=publicnode.com → GTS WE1 → GTS Root R4.
            // Pinned at CA level, not leaf, so the ~90-day leaf rotation
            // doesn't brick the host.
            "ethereum-rpc.publicnode.com": [
                "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=", // Google Trust Services WE1
                "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c=", // GTS Root R4 (backup CA)
            ],
            // Blockstream (Bitcoin API)
            "blockstream.info": [
                "FfFKxFycfaIz00eRZOgTf+Ne4POK6FgYPwhGDqSNkNQ=", // Let's Encrypt R3
                "jQJTbIh0grw0/1TkHSumWb+Fs0Ggogr621gT3PvPKG0=", // ISRG Root X1 (backup CA)
            ],
            // Solana Mainnet (Triton / shared infrastructure)
            "api.mainnet-beta.solana.com": [
                "FfFKxFycfaIz00eRZOgTf+Ne4POK6FgYPwhGDqSNkNQ=", // Let's Encrypt R3
                "jQJTbIh0grw0/1TkHSumWb+Fs0Ggogr621gT3PvPKG0=", // ISRG Root X1 (backup CA)
            ],
        ]
        for (host, pins) in known {
            pinnedHashes[host] = pins
        }
        // Freeze the known-host set so validate() can distinguish these
        // from user-configured TOFU hosts.
        knownHosts = Set(known.keys)
    }

    // MARK: - TOFU Persistence

    private func loadTOFUPins() {
        guard let data = try? KeychainManager.shared.retrieve(key: tofuKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return
        }
        for (host, hashes) in decoded {
            pinnedHashes[host] = Set(hashes)
        }
    }

    private func saveTOFUPins() {
        let serializable = pinnedHashes.mapValues { Array($0) }
        guard let data = try? JSONEncoder().encode(serializable) else { return }
        try? KeychainManager.shared.storeProtected(key: tofuKey, data: data)
    }
}

// MARK: - Pinned URLSession

/// A URLSession configured with certificate pinning.
final class PinnedURLSession: NSObject, URLSessionDelegate {
    static let shared = PinnedURLSession()

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // First: standard system validation
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(serverTrust, policy)

        var secResult: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &secResult) else {
            SecureLog.error("TLS validation failed for \(host): \(secResult?.localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Second: SPKI pin validation
        if CertificatePinner.shared.validate(serverTrust: serverTrust, host: host) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            SecureLog.error("Certificate pin mismatch for \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
