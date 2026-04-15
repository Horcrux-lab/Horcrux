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
final class CertificatePinner: NSObject {
    static let shared = CertificatePinner()

    /// Known SPKI hashes for default RPC endpoints (base64-encoded SHA-256).
    /// These are the public key pins for the default node providers.
    /// When providers rotate certs (but keep the same key), pins remain valid.
    private var pinnedHashes: [String: Set<String>] = [:]

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

        // Check against known pins
        if let knownPins = pinnedHashes[host], !knownPins.isEmpty {
            return !knownPins.isDisjoint(with: serverHashes)
        }

        // TOFU: no pins yet → trust and store the leaf hash
        if let firstHash = serverHashes.first {
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
    /// In production, replace placeholder hashes with real SPKI hashes.
    private func registerKnownPins() {
        // TODO: Replace with actual SPKI hashes from provider certificates
        // pinnedHashes["eth.llamarpc.com"] = ["<base64-spki-hash>"]
        // pinnedHashes["blockstream.info"] = ["<base64-spki-hash>"]
        // pinnedHashes["api.mainnet-beta.solana.com"] = ["<base64-spki-hash>"]
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
        try? KeychainManager.shared.store(key: tofuKey, data: data)
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
