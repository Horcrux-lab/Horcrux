import Foundation

/// High-level Swift wrapper around the UniFFI-generated Rust bindings.
/// Provides async/await APIs and Swift-native types.
@MainActor
final class HorcruxBridge: ObservableObject {
    private let session: HorcruxSessionManager
    private let shards: HorcruxShardManager

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

    /// Process incoming MPC messages and produce outgoing messages.
    /// Returns empty array when the round is complete and waiting for more input.
    func processMessages(sessionId: String, messages: [FfiMpcMessage]) throws -> [FfiMpcMessage] {
        try session.processMessages(sessionId: sessionId, messages: messages)
    }

    /// Finalize DKG and retrieve the keygen result (shard + group public key).
    func finalizeKeygen(sessionId: String) throws -> FfiKeygenResult {
        try session.finalizeKeygen(sessionId: sessionId)
    }

    // MARK: - Signing

    /// Start a signing session. Returns first round messages.
    func startSigning(sessionId: String, config: FfiHorcruxConfig,
                      keyShare: Data, message: Data) throws -> [FfiMpcMessage] {
        try session.createSigning(
            sessionId: sessionId,
            config: config,
            keyShare: [UInt8](keyShare),
            message: [UInt8](message)
        )
    }

    /// Finalize signing and retrieve the signature.
    func finalizeSigning(sessionId: String) throws -> FfiSigningResult {
        try session.finalizeSigning(sessionId: sessionId)
    }

    // MARK: - Chain Address Derivation

    func evmAddress(publicKey: Data) throws -> String {
        try horcruxEvmAddress(compressedPubkey: [UInt8](publicKey))
    }

    func btcAddress(publicKey: Data) throws -> String {
        try horcruxBtcAddress(compressedPubkey: [UInt8](publicKey))
    }

    func solanaAddress(publicKey: Data) throws -> String {
        try horcruxSolanaAddress(edPubkey: [UInt8](publicKey))
    }

    // MARK: - Shard Management

    func listShards() -> [FfiShardInfo] {
        shards.listShards()
    }

    func importShard(id: String, data: Data) throws {
        try shards.importShard(id: id, data: [UInt8](data))
    }

    func exportShard(id: String) throws -> Data {
        Data(try shards.exportShard(id: id))
    }

    func deleteShard(id: String) throws {
        try shards.deleteShard(id: id)
    }

    // MARK: - Shard Encryption

    func encryptShard(data: Data, pin: String) throws -> FfiEncryptedShard {
        try horcruxEncryptShard(shardData: [UInt8](data), pin: pin)
    }

    func decryptShard(encrypted: FfiEncryptedShard, pin: String) throws -> Data {
        Data(try horcruxDecryptShard(encrypted: encrypted, pin: pin))
    }

    // MARK: - Noise E2E Encryption

    func generateNoiseKeypair() -> FfiNoiseKeypair {
        horcruxNoiseKeypairGenerate()
    }
}
