import XCTest
@testable import Horcrux

/// Issue #32: "Speed up" rebuilt the payment by re-running coin selection
/// over *confirmed* UTXOs. A replacement that does not spend an outpoint
/// the original also spends does not conflict with it, so both can
/// confirm and the recipient is paid twice. The planner exists so that
/// the replacement's input set is derived from the original transaction
/// rather than chosen afresh.
///
/// Entirely offline and pure — no network, no view model.
final class BtcReplacementPlannerTests: XCTestCase {

    /// scriptPubKey of the wallet doing the replacing: OP_0 <20-byte program>.
    private let ownSPK = "0014" + String(repeating: "ab", count: 20)
    private let foreignSPK = "0014" + String(repeating: "cd", count: 20)

    private func original(
        inputs: [(txid: String, vout: UInt32, value: UInt64, spk: String)] = [
            ("aa".repeated(32), 1, 1_000_000, "0014" + String(repeating: "ab", count: 20))
        ],
        fee: UInt64 = 1_410,
        confirmed: Bool = false,
        sequence: UInt32 = 0xFFFF_FFFD
    ) -> BlockchainService.BtcTx {
        BlockchainService.BtcTx(
            txid: "ff".repeated(32),
            vin: inputs.map {
                BlockchainService.BtcTx.Vin(
                    txid: $0.txid,
                    vout: $0.vout,
                    prevout: BlockchainService.BtcTx.Prevout(scriptpubkey: $0.spk, value: $0.value),
                    sequence: sequence
                )
            },
            fee: fee,
            status: BlockchainService.BtcTx.Status(confirmed: confirmed)
        )
    }

    private func plan(
        _ tx: BlockchainService.BtcTx,
        sendSats: UInt64 = 500_000,
        feeRate: UInt64 = 20,
        vbytes: UInt64 = 141
    ) throws -> BtcReplacementPlan {
        try BtcReplacementPlanner.plan(
            replacing: tx,
            ownScriptPubkeyHex: ownSPK,
            sendSats: sendSats,
            feeRateSatPerVbyte: feeRate,
            estimatedVbytes: vbytes
        )
    }

    // MARK: - The defect itself

    /// The whole point: the replacement spends exactly the outpoints the
    /// original spends. Anything else is a second independent payment.
    func testReplacementSpendsTheOriginalsOwnOutpoints() throws {
        let tx = original(inputs: [("aa".repeated(32), 7, 1_000_000, ownSPK)])
        let result = try plan(tx)
        XCTAssertEqual(result.inputs.count, 1)
        XCTAssertEqual(result.inputs[0].txid, "aa".repeated(32))
        XCTAssertEqual(result.inputs[0].vout, 7, "vout must be carried over, not defaulted to 0")
        XCTAssertEqual(result.inputs[0].value, 1_000_000)
    }

    /// A confirmed transaction cannot be replaced by anyone. Rebuilding
    /// one would be a straight second payment.
    func testRefusesToReplaceAConfirmedTransaction() {
        XCTAssertThrowsError(try plan(original(confirmed: true))) { error in
            XCTAssertEqual(error as? BtcReplacementError, .originalAlreadyConfirmed)
        }
    }

    /// Transactions built before the nSequence fix carry 0xfffffffe, which
    /// is *not* less than 0xffffffff-1 and therefore does not opt in.
    /// Replacing them is impossible, so say so up front rather than after
    /// a full MPC ceremony ending in a rejected broadcast.
    func testRefusesWhenTheOriginalDidNotSignalBIP125() {
        XCTAssertThrowsError(try plan(original(sequence: 0xFFFF_FFFE))) { error in
            XCTAssertEqual(error as? BtcReplacementError, .originalNotReplaceable)
        }
    }

    func testAcceptsTheLargestSequenceThatStillOptsIn() throws {
        XCTAssertNoThrow(try plan(original(sequence: 0xFFFF_FFFD)))
    }

    /// We can only produce a signature for our own key. An input paying
    /// somebody else is not ours to re-sign.
    func testRefusesAnInputThatIsNotOurs() {
        let tx = original(inputs: [("aa".repeated(32), 0, 1_000_000, foreignSPK)])
        XCTAssertThrowsError(try plan(tx)) { error in
            XCTAssertEqual(error as? BtcReplacementError, .inputNotOwnedByWallet)
        }
    }

    /// scriptPubKey hex casing varies between Esplora deployments; a
    /// case-sensitive compare would reject our own input.
    func testOwnershipCompareIsCaseInsensitive() throws {
        let tx = original(inputs: [("aa".repeated(32), 0, 1_000_000, ownSPK.uppercased())])
        XCTAssertNoThrow(try plan(tx))
    }

    /// The finaliser splices exactly one signature
    /// (`BtcSigner.assembleSignedTx(signatures: [signature])`), so a
    /// multi-input original cannot be re-signed. Fail closed rather than
    /// produce a transaction with an unsigned input.
    func testRefusesAMultiInputOriginal() {
        let tx = original(inputs: [
            ("aa".repeated(32), 0, 600_000, ownSPK),
            ("bb".repeated(32), 1, 600_000, ownSPK)
        ])
        XCTAssertThrowsError(try plan(tx)) { error in
            XCTAssertEqual(error as? BtcReplacementError, .unsupportedInputCount(2))
        }
    }

    /// Coinbase vins carry no prevout, and neither do responses from an
    /// Esplora that omits it. Without a value we cannot build anything.
    func testRefusesAnInputWithNoPrevout() {
        let tx = BlockchainService.BtcTx(
            txid: "ff".repeated(32),
            vin: [BlockchainService.BtcTx.Vin(
                txid: "aa".repeated(32), vout: 0, prevout: nil, sequence: 0xFFFF_FFFD)],
            fee: 1_410,
            status: BlockchainService.BtcTx.Status(confirmed: false)
        )
        XCTAssertThrowsError(try plan(tx)) { error in
            XCTAssertEqual(error as? BtcReplacementError, .missingPrevout)
        }
    }

    // MARK: - BIP125 fee rules

    /// Rule 4: the replacement must pay for its own bandwidth at the
    /// incremental relay fee (1 sat/vB) *on top of* the original's fee.
    /// A tier that prices below that floor would be relayed nowhere.
    func testFeeIsRaisedToTheBIP125FloorWhenTheTierPricesBelowIt() throws {
        // 2 sat/vB × 141 vB = 282, well under 50 000 + 141.
        let result = try plan(original(fee: 50_000), feeRate: 2)
        XCTAssertEqual(result.feeSats, 50_000 + 141)
    }

    /// And when the tier prices above the floor, the tier wins — a "fast"
    /// replacement should actually be fast.
    func testFeeFollowsTheTierWhenItExceedsTheFloor() throws {
        let result = try plan(original(fee: 1_000), feeRate: 20)
        XCTAssertEqual(result.feeSats, 20 * 141)
        XCTAssertGreaterThan(result.feeSats, 1_000 + 141)
    }

    /// Rule 3 restated as an invariant that holds no matter which branch
    /// above wins.
    func testReplacementFeeAlwaysExceedsTheOriginals() throws {
        for originalFee in [UInt64(0), 1, 141, 2_820, 50_000, 1_000_000] {
            for rate in [UInt64(1), 2, 20, 300] {
                let result = try plan(
                    original(inputs: [("aa".repeated(32), 0, 5_000_000, ownSPK)], fee: originalFee),
                    sendSats: 1_000, feeRate: rate)
                XCTAssertGreaterThan(
                    result.feeSats, originalFee,
                    "fee \(result.feeSats) does not beat original \(originalFee) at \(rate) sat/vB")
            }
        }
    }

    // MARK: - Change and shortfall

    func testChangeIsWhatIsLeftAfterTheRecipientAndTheFee() throws {
        let tx = original(inputs: [("aa".repeated(32), 0, 1_000_000, ownSPK)], fee: 1_000)
        let result = try plan(tx, sendSats: 500_000, feeRate: 20)
        XCTAssertEqual(result.changeSats, 1_000_000 - 500_000 - 20 * 141)
    }

    /// A change output below the dust limit is unrelayable, so it is
    /// dropped — and the satoshis go to the miner rather than vanishing.
    func testSubDustChangeIsAbsorbedIntoTheFeeRatherThanCreatingADustOutput() throws {
        // Leave exactly 545 sats of change at the tier fee: 1 sat under dust.
        let fee = UInt64(20 * 141)
        let value = 500_000 + fee + 545
        let tx = original(inputs: [("aa".repeated(32), 0, value, ownSPK)], fee: 1_000)
        let result = try plan(tx, sendSats: 500_000, feeRate: 20)
        XCTAssertEqual(result.changeSats, 0, "dust change must not become an output")
        XCTAssertEqual(result.feeSats, fee + 545, "the dust must go to the fee, not disappear")
        XCTAssertEqual(result.inputs[0].value, result.feeSats + 500_000 + result.changeSats,
                       "value must balance exactly")
    }

    func testDustSizedChangeExactlyAtTheLimitIsKept() throws {
        let fee = UInt64(20 * 141)
        let value = 500_000 + fee + 546
        let tx = original(inputs: [("aa".repeated(32), 0, value, ownSPK)], fee: 1_000)
        let result = try plan(tx, sendSats: 500_000, feeRate: 20)
        XCTAssertEqual(result.changeSats, 546)
    }

    /// The original's own inputs are all we have. If bumping the fee costs
    /// more than the change can absorb, there is no valid replacement —
    /// and quietly picking a different UTXO is precisely the bug.
    func testRefusesWhenTheOriginalsInputsCannotCoverTheBumpedFee() {
        let tx = original(inputs: [("aa".repeated(32), 0, 502_000, ownSPK)], fee: 1_000)
        XCTAssertThrowsError(try plan(tx, sendSats: 500_000, feeRate: 20)) { error in
            XCTAssertEqual(error as? BtcReplacementError, .insufficientValue)
        }
    }

    func testRefusesAnOriginalWithNoInputsAtAll() {
        let tx = BlockchainService.BtcTx(
            txid: "ff".repeated(32), vin: [], fee: 0,
            status: BlockchainService.BtcTx.Status(confirmed: false))
        XCTAssertThrowsError(try plan(tx)) { error in
            XCTAssertEqual(error as? BtcReplacementError, .unsupportedInputCount(0))
        }
    }

    /// Every rejection reaches the user, so none of them may be blank.
    func testEveryErrorHasAUserFacingDescription() {
        let all: [BtcReplacementError] = [
            .originalAlreadyConfirmed, .originalNotReplaceable, .inputNotOwnedByWallet,
            .unsupportedInputCount(2), .missingPrevout, .insufficientValue
        ]
        for error in all {
            XCTAssertFalse(
                error.errorDescription?.isEmpty ?? true,
                "\(error) has no description, so the user would see an empty alert")
        }
    }

    // MARK: - Unsigned skeleton

    private let pubkeyHash = Data(repeating: 0xab, count: 20)
    private let recipientSPK = Data([0x00, 0x14] + [UInt8](repeating: 0xcd, count: 20))

    private func skeleton(sendSats: UInt64 = 500_000, changeSats: UInt64) -> FfiBtcTxParams {
        BtcTxSkeleton.params(
            inputs: [BtcSpendInput(txid: "aa".repeated(32), vout: 3, value: 1_000_000)],
            ownPubkeyHash: pubkeyHash,
            ownAddress: "bc1qown",
            recipientAddress: "bc1qrecipient",
            recipientScriptPubkey: recipientSPK,
            sendSats: sendSats,
            changeSats: changeSats
        )
    }

    func testSkeletonCarriesTheSelectedOutpoint() {
        let params = skeleton(changeSats: 100_000)
        XCTAssertEqual(params.inputs.count, 1)
        XCTAssertEqual(params.inputs[0].txid, "aa".repeated(32))
        XCTAssertEqual(params.inputs[0].vout, 3)
        XCTAssertEqual(params.inputs[0].value, 1_000_000)
        XCTAssertEqual(params.inputs[0].pubkeyHash, pubkeyHash)
        XCTAssertFalse(params.testnet)
    }

    func testSkeletonPaysTheRecipientFirst() {
        let params = skeleton(sendSats: 500_000, changeSats: 100_000)
        XCTAssertEqual(params.outputs.first?.value, 500_000)
        XCTAssertEqual(params.outputs.first?.scriptPubkey, recipientSPK)
        XCTAssertEqual(params.outputs.first?.address, "bc1qrecipient")
    }

    func testSkeletonReturnsChangeToOurOwnWitnessProgram() {
        let params = skeleton(changeSats: 100_000)
        XCTAssertEqual(params.outputs.count, 2)
        XCTAssertEqual(params.outputs[1].value, 100_000)
        XCTAssertEqual(params.outputs[1].address, "bc1qown")
        XCTAssertEqual(params.outputs[1].scriptPubkey, Data([0x00, 0x14]) + pubkeyHash,
                       "change must pay our own P2WPKH program, not the recipient's")
    }

    /// The planner folds sub-dust change into the fee; the skeleton must
    /// then not emit a zero-valued output, which no node would relay.
    func testSkeletonOmitsTheChangeOutputWhenThereIsNoChange() {
        let params = skeleton(changeSats: 0)
        XCTAssertEqual(params.outputs.count, 1)
    }

    // MARK: - End to end, across the FFI boundary

    /// Issue #32 stated as one assertion on the bytes that would actually
    /// be broadcast: plan → skeleton → Rust builder, and the result must
    /// spend the original's outpoint (so the two conflict) and carry an
    /// nSequence that opts into BIP125 (so a node will accept the
    /// replacement at all).
    func testBuiltReplacementSpendsTheOriginalOutpointAndSignalsBIP125() throws {
        // Asymmetric txid so the little-endian reversal is really checked.
        let originalInputTxid = "aa".repeated(31) + "bb"
        let tx = original(inputs: [(originalInputTxid, 3, 1_000_000, ownSPK)], fee: 1_000)
        let result = try plan(tx, sendSats: 500_000, feeRate: 20)

        let params = BtcTxSkeleton.params(
            inputs: result.inputs,
            ownPubkeyHash: pubkeyHash,
            ownAddress: "bc1qown",
            recipientAddress: "bc1qrecipient",
            recipientScriptPubkey: recipientSPK,
            sendSats: 500_000,
            changeSats: result.changeSats
        )
        let raw = [UInt8](try horcruxBuildBtcTransaction(params: params, inputIndex: 0).rawData)

        var p = 4 // version
        XCTAssertEqual(Array(raw[p..<(p + 2)]), [0x00, 0x01], "expected segwit marker+flag")
        p += 2
        XCTAssertEqual(raw[p], 1, "expected exactly one input")
        p += 1

        let txidBytes = Array(raw[p..<(p + 32)])
        XCTAssertEqual(
            Data(txidBytes.reversed()).map { String(format: "%02x", $0) }.joined(),
            originalInputTxid,
            "the replacement does not spend the original's outpoint, so it is a second payment")
        p += 32

        let vout = UInt32(raw[p]) | UInt32(raw[p + 1]) << 8
            | UInt32(raw[p + 2]) << 16 | UInt32(raw[p + 3]) << 24
        XCTAssertEqual(vout, 3)
        p += 4

        XCTAssertEqual(raw[p], 0x00, "P2WPKH scriptSig must be empty")
        p += 1

        let sequence = UInt32(raw[p]) | UInt32(raw[p + 1]) << 8
            | UInt32(raw[p + 2]) << 16 | UInt32(raw[p + 3]) << 24
        XCTAssertLessThan(
            sequence, UInt32(0xFFFF_FFFF) - 1,
            "nSequence \(String(sequence, radix: 16)) does not opt into BIP125, so no node "
            + "will accept a replacement for it")
    }
}

private extension String {
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}
