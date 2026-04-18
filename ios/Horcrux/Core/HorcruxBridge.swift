import Foundation

/// High-level Swift wrapper around the UniFFI-generated Rust bindings.
/// Provides async/await APIs and Swift-native types.
@MainActor
final class HorcruxBridge: ObservableObject {
    let session: HorcruxSessionManager
    let shards: HorcruxShardManager

    init(session: HorcruxSessionManager = HorcruxSessionManager(),
         shards: HorcruxShardManager = HorcruxShardManager()) {
        self.session = session
        self.shards = shards
    }

    // MARK: - Key Generation

    /// Start a DKG session. Returns the first round of MPC messages to send to peers.
    func startKeygen(sessionId: String, config: FfiHorcruxConfig) throws -> [FfiMpcMessage] {
        try session.createKeygen(sessionId: sessionId, config: config)
    }

    /// Process a single incoming MPC message and produce outgoing messages.
    func handleMessage(_ msg: FfiMpcMessage) throws -> [FfiMpcMessage] {
        try session.handleMessage(msg: msg)
    }

    /// Retrieve the keygen result once all rounds are complete. Returns nil if not ready.
    func getKeygenResult(sessionId: String) -> FfiKeygenResult? {
        session.getKeygenResult(sessionId: sessionId)
    }

    // MARK: - Key Refresh (proactive share rotation)

    /// Start a CGGMP21 key refresh ceremony. Re-randomises the local shard
    /// while keeping the wallet's group public key unchanged. n-of-n only.
    func startRefresh(sessionId: String, config: FfiHorcruxConfig,
                      shardData: Data) throws -> [FfiMpcMessage] {
        try session.createRefresh(sessionId: sessionId, config: config, shardData: shardData)
    }

    /// Retrieve the refresh result once the ceremony completes. Returns nil
    /// while still in progress. The `publicKey` field is identical to the
    /// pre-refresh value; `shardData` is the new shard payload to persist.
    func getRefreshResult(sessionId: String) -> FfiKeygenResult? {
        session.getRefreshResult(sessionId: sessionId)
    }

    /// Clean up a finished session.
    func removeSession(sessionId: String) {
        session.removeSession(sessionId: sessionId)
    }

    // MARK: - Signing

    /// Start a signing session. Returns first round messages.
    func startSigning(sessionId: String, config: FfiHorcruxConfig,
                      messageHash: Data, shardData: Data,
                      participants: [UInt16]) throws -> [FfiMpcMessage] {
        try session.createSigning(
            sessionId: sessionId,
            config: config,
            messageHash: messageHash,
            shardData: shardData,
            participants: participants
        )
    }

    /// Retrieve the signing result once all rounds are complete. Returns nil if not ready.
    func getSigningResult(sessionId: String) -> FfiSigningResult? {
        session.getSigningResult(sessionId: sessionId)
    }

    // MARK: - Chain Address Derivation

    func evmAddress(uncompressedPublicKey: Data) throws -> String {
        try horcruxEvmAddress(uncompressedPubkey: uncompressedPublicKey)
    }

    func btcAddress(compressedPublicKey: Data, hrp: String = "bc") throws -> String {
        try horcruxBtcAddress(compressedPubkey: compressedPublicKey, hrp: hrp)
    }

    func solanaAddress(publicKey: Data) throws -> String {
        try horcruxSolanaAddress(pubkey: publicKey)
    }

    /// Derive an on-chain address from the group public key for the given chain.
    func deriveAddress(chain: Chain, publicKey: Data) throws -> String {
        if chain.isEVM {
            // All EVM-family chains share the same keccak-based derivation.
            return try evmAddress(uncompressedPublicKey: publicKey)
        }
        switch chain {
        case .bitcoin:
            return try btcAddress(compressedPublicKey: publicKey)
        case .litecoin:
            // Litecoin SegWit P2WPKH shares BTC's bech32 scheme; hrp is "ltc".
            return try btcAddress(compressedPublicKey: publicKey, hrp: "ltc")
        case .solana:
            return try solanaAddress(publicKey: publicKey)
        case .tron:
            return try TronAddress.derive(uncompressedPublicKey: publicKey)
        default:
            throw NSError(domain: "HorcruxBridge", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported chain: \(chain)"])
        }
    }

    // MARK: - Shard Management

    func addShard(info: FfiShardInfo) {
        shards.addShard(info: info)
    }

    func listShards() -> [FfiShardInfo] {
        shards.listShards()
    }

    func shardsForKey(publicKey: Data) -> [FfiShardInfo] {
        shards.shardsForKey(publicKey: publicKey)
    }

    // MARK: - Shard Encryption

    func encryptShard(plaintext: Data, deviceKey: Data, pin: Data) throws -> FfiEncryptedShard {
        try horcruxEncryptShard(plaintext: plaintext, deviceKey: deviceKey, pin: pin)
    }

    func decryptShard(encrypted: FfiEncryptedShard, deviceKey: Data, pin: Data) throws -> Data {
        try horcruxDecryptShard(encrypted: encrypted, deviceKey: deviceKey, pin: pin)
    }

    // MARK: - Noise E2E Encryption

    func generateNoiseKeypair() throws -> FfiNoiseKeypair {
        try horcruxGenerateNoiseKeypair()
    }

    func generateSessionToken() throws -> FfiSessionToken {
        try horcruxGenerateSessionToken()
    }

    // MARK: - Hashing

    func keccak256(_ data: Data) -> Data {
        horcruxKeccak256(data: data)
    }
}
