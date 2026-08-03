import Foundation

/// One outpoint a transaction spends.
struct BtcSpendInput: Equatable, Sendable {
    let txid: String
    let vout: UInt32
    let value: UInt64
}

/// Assembles the unsigned P2WPKH skeleton handed to the Rust builder.
///
/// Shared by the ordinary send path and the replace-by-fee rebuild so the
/// two cannot drift in how they pay the recipient or return change — the
/// drift between them is what issue #32 was.
enum BtcTxSkeleton {
    static func params(
        inputs: [BtcSpendInput],
        ownPubkeyHash: Data,
        ownAddress: String,
        recipientAddress: String,
        recipientScriptPubkey: Data,
        sendSats: UInt64,
        changeSats: UInt64
    ) -> FfiBtcTxParams {
        var outputs: [FfiBtcOutput] = [
            FfiBtcOutput(
                address: recipientAddress, value: sendSats, scriptPubkey: recipientScriptPubkey)
        ]
        if changeSats > 0 {
            outputs.append(FfiBtcOutput(
                address: ownAddress,
                value: changeSats,
                scriptPubkey: Data([0x00, 0x14]) + ownPubkeyHash))
        }
        return FfiBtcTxParams(
            inputs: inputs.map {
                FfiBtcInput(
                    txid: $0.txid, vout: $0.vout, value: $0.value,
                    pubkeyHash: ownPubkeyHash, prevTxRaw: nil)
            },
            outputs: outputs,
            testnet: false
        )
    }
}

/// What to build in place of a stuck transaction.
struct BtcReplacementPlan: Equatable, Sendable {
    /// The original's own outpoints, unchanged. This is what makes the
    /// new transaction a *replacement* rather than a second payment.
    let inputs: [BtcSpendInput]
    let feeSats: UInt64
    /// Zero when what is left over would be an unrelayable dust output.
    let changeSats: UInt64
}

/// The original transaction could not be loaded, which is a network
/// problem rather than one of `BtcReplacementError`'s substantive
/// refusals. Kept separate so the user is not told their transaction is
/// unreplaceable when nothing could be reached.
enum BtcReplacementFetchError: Error, Equatable, LocalizedError {
    case originalUnavailable

    var errorDescription: String? { L10n.Signing.rbfOriginalUnavailable }
}

enum BtcReplacementError: Error, Equatable, LocalizedError {
    case originalAlreadyConfirmed
    case originalNotReplaceable
    case inputNotOwnedByWallet
    case unsupportedInputCount(Int)
    case missingPrevout
    case insufficientValue

    var errorDescription: String? {
        switch self {
        case .originalAlreadyConfirmed:
            return L10n.Signing.rbfAlreadyConfirmed
        case .originalNotReplaceable:
            return L10n.Signing.rbfNotReplaceable
        case .inputNotOwnedByWallet:
            return L10n.Signing.rbfForeignInput
        case .unsupportedInputCount:
            return L10n.Signing.rbfUnsupportedInputCount
        case .missingPrevout:
            return L10n.Signing.rbfMissingPrevout
        case .insufficientValue:
            return L10n.Signing.rbfInsufficientValue
        }
    }
}

/// Derives the replacement for a stuck Bitcoin/Litecoin transaction from
/// the transaction being replaced.
///
/// Issue #32: "Speed up" used to re-run ordinary coin selection over
/// *confirmed* UTXOs. Esplora removes outputs spent by mempool
/// transactions from `/address/:addr/utxo` entirely, and the original's
/// own change output is unconfirmed by definition, so the rebuild could
/// not pick the original's inputs even by accident. It picked a different
/// UTXO, the two transactions did not conflict, and both could confirm —
/// paying the recipient twice.
///
/// Nothing here touches the network: the caller fetches the original and
/// hands it over, so every rule below is exercised by ordinary unit tests.
enum BtcReplacementPlanner {

    /// Bitcoin Core's default `-incrementalrelayfee`, in sat/vB. BIP-125
    /// rule 4 requires the replacement to pay this much per vbyte *on top
    /// of* the fee the original paid.
    static let incrementalRelayFeeSatPerVbyte: UInt64 = 1

    /// Below this a P2WPKH output is not relayed.
    static let dustSats: UInt64 = 546

    /// The largest nSequence that still counts as BIP-125 opt-in, i.e.
    /// strictly less than `0xffffffff - 1`.
    static let maxReplaceableSequence: UInt32 = 0xFFFF_FFFD

    static func plan(
        replacing original: BlockchainService.BtcTx,
        ownScriptPubkeyHex: String,
        sendSats: UInt64,
        feeRateSatPerVbyte: UInt64,
        estimatedVbytes: UInt64
    ) throws -> BtcReplacementPlan {
        guard !original.status.confirmed else {
            throw BtcReplacementError.originalAlreadyConfirmed
        }

        // The finaliser splices exactly one signature, so a multi-input
        // original cannot be re-signed. Refusing is the honest outcome;
        // selecting a different input is the bug being fixed.
        guard original.vin.count == 1 else {
            throw BtcReplacementError.unsupportedInputCount(original.vin.count)
        }
        let vin = original.vin[0]

        // A nil sequence means the endpoint did not tell us, which is not
        // the same as "it opted in". Fail closed.
        guard let sequence = vin.sequence, sequence <= maxReplaceableSequence else {
            throw BtcReplacementError.originalNotReplaceable
        }

        guard let prevout = vin.prevout else {
            throw BtcReplacementError.missingPrevout
        }
        guard prevout.scriptpubkey.lowercased() == ownScriptPubkeyHex.lowercased() else {
            throw BtcReplacementError.inputNotOwnedByWallet
        }

        // BIP-125 rules 3 and 4: beat the original's absolute fee, and pay
        // the incremental relay fee for the replacement's own size. A tier
        // that prices under that floor gets raised to it.
        let tierFee = feeRateSatPerVbyte * estimatedVbytes
        let bip125Floor = original.fee + incrementalRelayFeeSatPerVbyte * estimatedVbytes
        var feeSats = max(tierFee, bip125Floor)

        let totalIn = prevout.value
        guard totalIn >= sendSats, totalIn - sendSats >= feeSats else {
            throw BtcReplacementError.insufficientValue
        }
        var changeSats = totalIn - sendSats - feeSats
        if changeSats < dustSats {
            // An output nobody will relay is worse than a slightly larger
            // fee, and dropping it silently would make the value stop
            // balancing.
            feeSats += changeSats
            changeSats = 0
        }

        return BtcReplacementPlan(
            inputs: [BtcSpendInput(txid: vin.txid, vout: vin.vout, value: prevout.value)],
            feeSats: feeSats,
            changeSats: changeSats
        )
    }
}
