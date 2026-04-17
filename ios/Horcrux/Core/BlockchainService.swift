import Foundation

/// Thin JSON-RPC / REST client for on-chain queries and transaction broadcast.
/// Supports Ethereum (JSON-RPC), Bitcoin (Blockstream REST), and Solana (JSON-RPC).
actor BlockchainService {
    private let session: URLSession

    /// Limits concurrent RPC requests to prevent endpoint rate-limiting.
    private let maxConcurrentRequests = 3
    private var activeRequests = 0

    private func waitForSlot() async {
        while activeRequests >= maxConcurrentRequests {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms backoff
        }
        activeRequests += 1
    }

    private func releaseSlot() {
        activeRequests = max(0, activeRequests - 1)
    }

    init(session: URLSession? = nil) {
        self.session = session ?? PinnedURLSession.shared.session
    }

    // MARK: - Retry with Exponential Backoff

    /// Maximum retry attempts for transient RPC failures.
    private let maxRetries = 3

    /// Execute a block with exponential backoff on transient errors.
    private func withRetry<T>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch let error as BlockchainError where error.isTransient {
                lastError = error
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                lastError = error
            } catch {
                throw error
            }
            let baseDelay: UInt64 = 500_000_000 // 500ms
            let jitter = UInt64.random(in: 0...200_000_000)
            let delay = baseDelay * UInt64(1 << attempt) + jitter
            try? await Task.sleep(nanoseconds: delay)
            SecureLog.warning("RPC retry \(attempt + 1)/\(maxRetries)")
        }
        throw lastError ?? BlockchainError.invalidResponse
    }

    /// Validate and construct a URL, rejecting non-HTTPS schemes.
    private static func validatedURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https" else {
            throw BlockchainError.invalidURL(urlString)
        }
        return url
    }

    /// Validate an address contains only safe characters (alphanumeric + base58/hex).
    private static func sanitizedAddress(_ address: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "xX"))
        guard address.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw BlockchainError.invalidAddress
        }
        return address
    }

    // MARK: - Ethereum (JSON-RPC)

    struct EvmGasEstimate {
        let nonce: UInt64
        let gasLimit: UInt64
        let maxFeePerGas: String       // wei decimal
        let maxPriorityFeePerGas: String // wei decimal
    }

    /// Fetch ETH balance in wei (decimal string).
    func ethBalance(address: String, rpcURL: String) async throws -> String {
        let result: String = try await ethCall(
            method: "eth_getBalance",
            params: [address, "latest"],
            rpcURL: rpcURL
        )
        return hexToDecimal(result)
    }

    /// Fetch current transaction count (nonce) for an address.
    func ethNonce(address: String, rpcURL: String) async throws -> UInt64 {
        let result: String = try await ethCall(
            method: "eth_getTransactionCount",
            params: [address, "latest"],
            rpcURL: rpcURL
        )
        return UInt64(hexToDecimal(result)) ?? 0
    }

    /// Estimate gas parameters for a simple transfer.
    func ethEstimateGas(from: String, to: String, valueWei: String, data txData: String? = nil, rpcURL: String) async throws -> EvmGasEstimate {
        let nonce = try await ethNonce(address: from, rpcURL: rpcURL)

        // Gas limit: use eth_estimateGas
        let valueHex = "0x" + String(UInt64(valueWei) ?? 0, radix: 16)
        var txObj: [String: String] = ["from": from, "to": to, "value": valueHex]
        if let txData, !txData.isEmpty { txObj["data"] = txData }
        let estimateParams: [[String: String]] = [txObj]
        let gasHex: String = try await ethCall(
            method: "eth_estimateGas",
            params: estimateParams,
            rpcURL: rpcURL
        )
        // Add 20% safety margin to gas limit
        let rawGas = UInt64(hexToDecimal(gasHex)) ?? 21000
        let gasLimit = rawGas + rawGas / 5

        // EIP-1559 fees: fetch both base fee and priority fee
        let gasPriceHex: String = try await ethCall(
            method: "eth_gasPrice",
            params: [] as [String],
            rpcURL: rpcURL
        )
        let gasPrice = UInt64(hexToDecimal(gasPriceHex)) ?? 0

        // Try to get real maxPriorityFeePerGas from node
        var priorityFeeWei: UInt64 = 1_500_000_000 // 1.5 gwei default
        do {
            let tipHex: String = try await ethCall(
                method: "eth_maxPriorityFeePerGas",
                params: [] as [String],
                rpcURL: rpcURL
            )
            priorityFeeWei = UInt64(hexToDecimal(tipHex)) ?? priorityFeeWei
        } catch {
            SecureLog.info("eth_maxPriorityFeePerGas not supported, using default")
        }

        // maxFeePerGas = 2 * baseFee + maxPriorityFeePerGas
        let maxFee = gasPrice * 2 + priorityFeeWei

        return EvmGasEstimate(
            nonce: nonce,
            gasLimit: gasLimit,
            maxFeePerGas: "\(maxFee)",
            maxPriorityFeePerGas: "\(priorityFeeWei)"
        )
    }

    /// Human-readable fee estimate for display (in ETH).
    func ethFeeEstimateDisplay(from: String, to: String, valueWei: String, rpcURL: String) async throws -> FeeEstimate {
        let gas = try await ethEstimateGas(from: from, to: to, valueWei: valueWei, rpcURL: rpcURL)
        let maxFeeWei = Decimal(string: gas.maxFeePerGas) ?? 0
        let maxCostWei = Decimal(gas.gasLimit) * maxFeeWei
        let ethCost = maxCostWei / Decimal(1_000_000_000_000_000_000)
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 8
        formatter.minimumFractionDigits = 4
        let formatted = formatter.string(from: ethCost as NSDecimalNumber) ?? "\(ethCost)"
        return FeeEstimate(
            chain: .ethereum,
            estimatedFee: "\(formatted) ETH",
            feeDetails: "Gas: \(gas.gasLimit) × \(gas.maxFeePerGas) wei"
        )
    }

    /// Broadcast a signed EVM transaction. Returns the tx hash.
    func ethSendRawTransaction(signedTxHex: String, rpcURL: String) async throws -> String {
        try await ethCall(
            method: "eth_sendRawTransaction",
            params: [signedTxHex],
            rpcURL: rpcURL
        )
    }

    // MARK: - Bitcoin (Blockstream REST API)

    struct BtcUtxo: Decodable {
        let txid: String
        let vout: UInt32
        let value: UInt64
        struct Status: Decodable {
            let confirmed: Bool
        }
        let status: Status
    }

    /// Human-readable BTC fee estimate.
    func btcFeeEstimateDisplay(inputCount: Int, outputCount: Int, apiURL: String) async throws -> FeeEstimate {
        let rates = try await btcFeeEstimate(apiURL: apiURL)
        // Estimate vbytes: ~68 per input + 31 per output + 10 overhead (P2WPKH)
        let vbytes = UInt64(inputCount * 68 + outputCount * 31 + 10)
        let fastSats = vbytes * rates.fastestFee
        let medSats = vbytes * rates.halfHourFee
        let btcFast = Decimal(fastSats) / Decimal(100_000_000)
        let btcMed = Decimal(medSats) / Decimal(100_000_000)
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 8
        let fastStr = formatter.string(from: btcFast as NSDecimalNumber) ?? "\(btcFast)"
        let medStr = formatter.string(from: btcMed as NSDecimalNumber) ?? "\(btcMed)"
        return FeeEstimate(
            chain: .bitcoin,
            estimatedFee: "\(medStr) – \(fastStr) BTC",
            feeDetails: "~\(vbytes) vB × \(rates.halfHourFee)–\(rates.fastestFee) sat/vB"
        )
    }

    /// Fetch BTC balance in satoshis.
    func btcBalance(address: String, apiURL: String) async throws -> UInt64 {
        let utxos = try await btcUtxos(address: address, apiURL: apiURL)
        return utxos.reduce(0) { $0 + $1.value }
    }

    /// Fetch UTXOs for a Bitcoin address.
    func btcUtxos(address: String, apiURL: String) async throws -> [BtcUtxo] {
        let safe = try Self.sanitizedAddress(address)
        let url = try Self.validatedURL("\(apiURL)/address/\(safe)/utxo")
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        return try JSONDecoder().decode([BtcUtxo].self, from: data)
    }

    /// Fetch recommended fee rates (sat/vB).
    struct BtcFeeEstimate: Decodable {
        let fastestFee: UInt64
        let halfHourFee: UInt64
        let hourFee: UInt64
        let minimumFee: UInt64
    }

    func btcFeeEstimate(apiURL: String) async throws -> BtcFeeEstimate {
        let feeURLString = apiURL.contains("blockstream")
            ? "https://mempool.space/api/v1/fees/recommended"
            : "\(apiURL)/v1/fees/recommended"
        let url = try Self.validatedURL(feeURLString)
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        return try JSONDecoder().decode(BtcFeeEstimate.self, from: data)
    }

    /// Check if an EVM transaction has been mined. Returns:
    ///   - `.some(true)` if receipt exists and status == 0x1 (success)
    ///   - `.some(false)` if receipt exists and status == 0x0 (reverted)
    ///   - `nil` if the node hasn't seen a receipt yet (still pending)
    func ethTxConfirmed(txHash: String, rpcURL: String) async throws -> Bool? {
        // The node returns `null` for pending txs; Codable needs a wrapper.
        struct Receipt: Decodable {
            let status: String?
            let blockNumber: String?
        }
        let raw: Receipt? = try await ethCallOptional(
            method: "eth_getTransactionReceipt",
            params: [txHash],
            rpcURL: rpcURL
        )
        guard let receipt = raw, receipt.blockNumber != nil else { return nil }
        // status == "0x1" is success, "0x0" is reverted.
        if let st = receipt.status {
            return st == "0x1"
        }
        // Pre-Byzantium chains omit status; presence of blockNumber is enough.
        return true
    }

    /// Check if a Bitcoin/Litecoin transaction has confirmed. Calls Esplora's
    /// `/tx/{txid}/status` endpoint.
    func btcTxConfirmed(txid: String, apiURL: String) async throws -> Bool {
        struct Status: Decodable { let confirmed: Bool }
        let url = try Self.validatedURL("\(apiURL)/tx/\(txid)/status")
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        let status = try JSONDecoder().decode(Status.self, from: data)
        return status.confirmed
    }

    /// Broadcast a signed Bitcoin transaction (hex). Returns the txid.
    func btcBroadcast(signedTxHex: String, apiURL: String) async throws -> String {
        let url = try Self.validatedURL("\(apiURL)/tx")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = signedTxHex.data(using: .utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Solana (JSON-RPC)

    /// Fetch SOL balance in lamports.
    func solBalance(address: String, rpcURL: String) async throws -> UInt64 {
        struct BalanceResult: Decodable {
            let value: UInt64
        }
        let result: BalanceResult = try await solanaCall(
            method: "getBalance",
            params: [address],
            rpcURL: rpcURL
        )
        return result.value
    }

    /// Lightweight EVM health probe: returns the current block number as a
    /// decimal string. Cheap for public RPCs (no per-address quota) and
    /// verifies the endpoint speaks JSON-RPC.
    func ethBlockNumber(rpcURL: String) async throws -> String {
        let hex: String = try await ethCall(
            method: "eth_blockNumber",
            params: [] as [String],
            rpcURL: rpcURL
        )
        return hexToDecimal(hex)
    }

    /// Lightweight Solana health probe. Returns "ok" when the node is healthy.
    func solHealth(rpcURL: String) async throws -> String {
        let result: String = try await solanaCall(
            method: "getHealth",
            params: [] as [String],
            rpcURL: rpcURL
        )
        return result
    }

    // MARK: - TRON

    /// Fetch native TRX balance (in `sun` = 1e-6 TRX) via TronGrid's
    /// `/wallet/getaccount` HTTP endpoint with `visible=true` so we can pass
    /// the human-readable Base58 address directly.
    func tronBalance(address: String, apiURL: String) async throws -> UInt64 {
        guard let url = URL(string: "\(apiURL)/wallet/getaccount") else {
            throw BlockchainError.invalidURL(apiURL)
        }
        let body: [String: Any] = ["address": address, "visible": true]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        try validateHTTP(response)

        // TronGrid returns `{}` for a never-activated account. Balance field is
        // missing in that case — treat as zero, not an error.
        struct AccountResult: Decodable { let balance: UInt64? }
        let decoded = try JSONDecoder().decode(AccountResult.self, from: data)
        return decoded.balance ?? 0
    }

    /// TRON unsigned transaction handed back by TronGrid's
    /// `/wallet/createtransaction` (native TRX) and
    /// `/wallet/triggersmartcontract` (TRC-20) endpoints.
    struct TronUnsignedTx {
        let txID: String           // 32-byte hash in hex — this is what we sign.
        let rawDataHex: String     // protobuf-serialised raw_data; opaque to us.
        let rawDataJSON: [String: Any] // decoded raw_data object; needed for broadcast.
    }

    /// Ask TronGrid to build an unsigned native TRX transfer and return the
    /// 32-byte txID (sha256 of raw_data) that the MPC round will sign.
    ///
    /// Using the remote builder lets us avoid shipping a protobuf runtime in
    /// the app. The returned `raw_data_hex` is treated as opaque bytes — we
    /// never decode it, only hand it back on broadcast.
    func tronCreateTransaction(
        from: String, to: String, amountSun: UInt64, apiURL: String
    ) async throws -> TronUnsignedTx {
        guard let url = URL(string: "\(apiURL)/wallet/createtransaction") else {
            throw BlockchainError.invalidURL(apiURL)
        }
        let body: [String: Any] = [
            "owner_address": from,
            "to_address": to,
            "amount": amountSun,
            "visible": true,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        try validateHTTP(response)
        return try decodeTronUnsigned(data: data)
    }

    /// Estimate TRC-20 transfer energy + bandwidth via
    /// `/wallet/triggerconstantcontract`. Does NOT broadcast. Returns
    /// conservative fee in SUN: `energy_used × 420` (energy unit price as of
    /// 2024 Niles upgrade) plus `345 × 1000` for bandwidth (~345 bytes at
    /// 1000 SUN/byte when the account has no free bandwidth). Real cost is
    /// lower for accounts with staked/frozen resources, but this matches
    /// the on-chain `fee_limit` ceiling the signer needs to commit to.
    func tronEstimateTRC20Fee(
        from: String, contract: String, to: String, amountRaw: String, apiURL: String
    ) async throws -> (feeSun: UInt64, energy: UInt64) {
        guard let url = URL(string: "\(apiURL)/wallet/triggerconstantcontract") else {
            throw BlockchainError.invalidURL(apiURL)
        }
        let toHex20 = try tronBase58AddressToHex20(to)
        let addrPadded = String(repeating: "0", count: 24) + toHex20
        guard let amtPadded = decimalStringToABIUint256Hex(amountRaw) else {
            throw BlockchainError.invalidResponse
        }
        let parameter = addrPadded + amtPadded
        let body: [String: Any] = [
            "owner_address": from,
            "contract_address": contract,
            "function_selector": "transfer(address,uint256)",
            "parameter": parameter,
            "visible": true,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        try validateHTTP(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        let energyUsed: UInt64 = {
            if let n = json["energy_used"] as? NSNumber { return n.uint64Value }
            if let s = json["energy_used"] as? String, let v = UInt64(s) { return v }
            return 0
        }()
        // 420 SUN per energy unit (post-Niles), 1000 SUN per bandwidth byte.
        // ~345 bytes is typical for a TRC-20 transfer raw tx.
        let energySun = energyUsed * 420
        let bandwidthSun: UInt64 = 345 * 1_000
        return (feeSun: energySun + bandwidthSun, energy: energyUsed)
    }

    /// Build an unsigned TRC-20 `transfer(address,uint256)` call via
    /// `/wallet/triggersmartcontract`. Used for USDT-TRC20 and any other
    /// standard TRC-20 token.
    ///
    /// `to` is the recipient base58 address, `contract` is the token
    /// contract's base58 address (e.g. `TR7NHqjeK...` for USDT).
    func tronTriggerTRC20Transfer(
        from: String, contract: String, to: String, amountRaw: String,
        feeLimitSun: UInt64 = 40_000_000, apiURL: String
    ) async throws -> TronUnsignedTx {
        guard let url = URL(string: "\(apiURL)/wallet/triggersmartcontract") else {
            throw BlockchainError.invalidURL(apiURL)
        }
        // ABI-encode transfer(address,uint256):
        //   32 bytes: recipient address left-padded
        //   32 bytes: amount left-padded
        let toHex20 = try tronBase58AddressToHex20(to)
        let addrPadded = String(repeating: "0", count: 24) + toHex20
        guard let amtPadded = decimalStringToABIUint256Hex(amountRaw) else {
            throw BlockchainError.invalidResponse
        }
        let parameter = addrPadded + amtPadded

        let body: [String: Any] = [
            "owner_address": from,
            "contract_address": contract,
            "function_selector": "transfer(address,uint256)",
            "parameter": parameter,
            "fee_limit": feeLimitSun,
            "call_value": 0,
            "visible": true,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        try validateHTTP(response)
        // triggersmartcontract nests the tx under "transaction"; createtransaction
        // returns it at the top level. Handle both.
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = json["transaction"] as? [String: Any] {
            let innerData = try JSONSerialization.data(withJSONObject: inner)
            return try decodeTronUnsigned(data: innerData)
        }
        return try decodeTronUnsigned(data: data)
    }

    /// Broadcast a signed TRON transaction. `signatureHex` is the 65-byte
    /// (r||s||v) hex string produced by the MPC round, where v is the
    /// secp256k1 recovery id (0 or 1 — TRON does NOT add 27).
    func tronBroadcast(
        rawDataHex: String, rawDataJSON: [String: Any],
        signatureHex: String, apiURL: String
    ) async throws -> String {
        guard let url = URL(string: "\(apiURL)/wallet/broadcasttransaction") else {
            throw BlockchainError.invalidURL(apiURL)
        }
        // Need txID as well (the hash we signed) so TronGrid can verify.
        // The caller passes it via rawDataJSON → we also re-send raw_data_hex.
        var body: [String: Any] = [
            "raw_data": rawDataJSON,
            "raw_data_hex": rawDataHex,
            "signature": [signatureHex],
            "visible": true,
        ]
        // Some deployments require txID explicitly on broadcast.
        if let txID = rawDataJSON["txID"] as? String { body["txID"] = txID }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        try validateHTTP(response)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        if let ok = json["result"] as? Bool, ok {
            // TronGrid returns the submitted txID on success; fall back to
            // our local copy if the field is missing in some deployments.
            if let tx = json["txid"] as? String { return tx }
            if let tx = rawDataJSON["txID"] as? String { return tx }
            return ""
        }
        let code = (json["code"] as? String) ?? "UNKNOWN"
        let msgHex = (json["message"] as? String) ?? ""
        let msg = hexToUtf8(msgHex) ?? msgHex
        throw BlockchainError.invalidResponse
    }

    /// Poll `/wallet/gettransactionbyid` — returns true once the tx has
    /// landed in a block.
    func tronTxConfirmed(txID: String, apiURL: String) async throws -> Bool {
        guard let url = URL(string: "\(apiURL)/wallet/gettransactionbyid") else {
            return false
        }
        let body: [String: Any] = ["value": txID, "visible": true]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await session.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        // A mined tx carries `ret: [{contractRet: "SUCCESS"|"REVERT"|...}]`.
        // A pending / unknown tx returns `{}`.
        return (json["ret"] as? [[String: Any]])?.isEmpty == false
    }

    // MARK: - TRON helpers

    private func decodeTronUnsigned(data: Data) throws -> TronUnsignedTx {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        if let err = json["Error"] as? String {
            throw BlockchainError.invalidResponse
        }
        guard let txID = json["txID"] as? String,
              let rawDataHex = json["raw_data_hex"] as? String,
              let rawDataAny = json["raw_data"] as? [String: Any]
        else {
            throw BlockchainError.invalidResponse
        }
        // Keep txID inside rawDataJSON for the broadcast call; harmless duplicate.
        var withTxID = rawDataAny
        withTxID["txID"] = txID
        return TronUnsignedTx(txID: txID, rawDataHex: rawDataHex, rawDataJSON: withTxID)
    }

    /// Convert a base58-check TRON address (e.g. "TR7NHqjeK...") to its
    /// 20-byte hex form, stripping the 0x41 network prefix. Used for ABI
    /// encoding of TRC-20 calls.
    private func tronBase58AddressToHex20(_ address: String) throws -> String {
        guard let hex41 = Base58Check.decode(address) else {
            throw BlockchainError.invalidResponse
        }
        guard hex41.count == 21, hex41[0] == 0x41 else {
            throw BlockchainError.invalidResponse
        }
        return hex41.dropFirst().map { String(format: "%02x", $0) }.joined()
    }

    private func hexToUtf8(_ hex: String) -> String? {
        var bytes: [UInt8] = []
        var s = hex
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return String(data: Data(bytes), encoding: .utf8)
    }

    /// Fetch a recent blockhash for transaction construction.
    func solRecentBlockhash(rpcURL: String) async throws -> String {
        struct BlockhashResult: Decodable {
            struct Value: Decodable {
                let blockhash: String
            }
            let value: Value
        }
        let result: BlockhashResult = try await solanaCall(
            method: "getLatestBlockhash",
            params: [] as [String],
            rpcURL: rpcURL
        )
        return result.value.blockhash
    }

    /// Estimate Solana transaction fee (base fee + priority).
    func solFeeEstimateDisplay(rpcURL: String) async throws -> FeeEstimate {
        // Solana base fee is 5000 lamports per signature (fixed)
        // Try to get priority fee for better estimates
        var priorityLamports: UInt64 = 0
        do {
            struct PriorityFee: Decodable { let prioritizationFee: UInt64 }
            let fees: [PriorityFee] = try await solanaCall(
                method: "getRecentPrioritizationFees",
                params: [] as [String],
                rpcURL: rpcURL
            )
            // Use median priority fee
            let sorted = fees.map(\.prioritizationFee).sorted()
            if !sorted.isEmpty {
                priorityLamports = sorted[sorted.count / 2]
            }
        } catch {
            SecureLog.info("getRecentPrioritizationFees not available, using base fee only")
        }

        let totalLamports = 5000 + priorityLamports
        let sol = Decimal(totalLamports) / Decimal(1_000_000_000)
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 9
        formatter.minimumFractionDigits = 6
        let formatted = formatter.string(from: sol as NSDecimalNumber) ?? "\(sol)"
        return FeeEstimate(
            chain: .solana,
            estimatedFee: "\(formatted) SOL",
            feeDetails: "Base: 5000 + Priority: \(priorityLamports) lamports"
        )
    }

    /// Broadcast a signed Solana transaction (base64). Returns the signature.
    func solSendTransaction(signedTxBase64: String, rpcURL: String) async throws -> String {
        struct SendTxParams: Encodable {
            let tx: String
            let config: [String: String]
            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                try container.encode(tx)
                try container.encode(config)
            }
        }
        let params = SendTxParams(tx: signedTxBase64, config: ["encoding": "base64"])
        return try await solanaCall(
            method: "sendTransaction",
            params: params,
            rpcURL: rpcURL
        )
    }

    /// Check if a Solana signature has been confirmed. Uses
    /// `getSignatureStatuses` with `searchTransactionHistory: false` so we
    /// only peek at the recent statuses block (enough for freshly broadcast
    /// txs). Returns:
    ///   - true  — confirmationStatus is "confirmed" or "finalized"
    ///   - false — still "processed" or not found yet
    func solSigConfirmed(signature: String, rpcURL: String) async throws -> Bool {
        struct StatusesParams: Encodable {
            let sigs: [String]
            let config: [String: Bool]
            func encode(to encoder: Encoder) throws {
                var c = encoder.unkeyedContainer()
                try c.encode(sigs)
                try c.encode(config)
            }
        }
        struct Result: Decodable {
            struct Value: Decodable {
                let confirmationStatus: String?
                let err: AnyDecodable?
            }
            let value: [Value?]
        }
        // `AnyDecodable` is just a placeholder — we only check non-nil.
        struct AnyDecodable: Decodable {}
        let params = StatusesParams(
            sigs: [signature],
            config: ["searchTransactionHistory": false]
        )
        let result: Result = try await solanaCall(
            method: "getSignatureStatuses",
            params: params,
            rpcURL: rpcURL
        )
        guard let first = result.value.first, let entry = first else { return false }
        guard entry.err == nil else { return false }
        return entry.confirmationStatus == "confirmed" || entry.confirmationStatus == "finalized"
    }

    // MARK: - Generic balance fetch

    func balance(for wallet: Wallet, config: NetworkConfig) async throws -> String {
        let attempts = RPCFallbacks.orderedAttempts(for: wallet.chain, config: config)
        var lastError: Error = BlockchainError.invalidURL("no endpoints")
        for (idx, url) in attempts.enumerated() {
            do {
                if wallet.chain.isEVM {
                    let wei = try await ethBalance(address: wallet.address, rpcURL: url)
                    if idx > 0 { SecureLog.info("RPC fallback \(idx) succeeded for \(wallet.chain.symbol) balance") }
                    let symbol: String = {
                        if wallet.chain == .ethereum {
                            return EVMNetwork(rawValue: config.evmChainId)?.nativeSymbol ?? "ETH"
                        }
                        return wallet.chain.symbol
                    }()
                    return formatEthBalance(wei: wei, symbol: symbol)
                }
                switch wallet.chain {
                case .bitcoin:
                    let sats = try await btcBalance(address: wallet.address, apiURL: url)
                    if idx > 0 { SecureLog.info("RPC fallback \(idx) succeeded for BTC balance") }
                    return formatBtcBalance(satoshis: sats)
                case .litecoin:
                    // litecoinspace.org exposes the Esplora API, same shape as Blockstream.
                    let litoshi = try await btcBalance(address: wallet.address, apiURL: url)
                    if idx > 0 { SecureLog.info("RPC fallback \(idx) succeeded for LTC balance") }
                    return formatGenericSatoshis(litoshi, symbol: "LTC")
                case .solana:
                    let lamports = try await solBalance(address: wallet.address, rpcURL: url)
                    if idx > 0 { SecureLog.info("RPC fallback \(idx) succeeded for SOL balance") }
                    return formatSolBalance(lamports: lamports)
                case .tron:
                    let sun = try await tronBalance(address: wallet.address, apiURL: url)
                    if idx > 0 { SecureLog.info("RPC fallback \(idx) succeeded for TRX balance") }
                    return formatTronBalance(sun: sun)
                default:
                    throw BlockchainError.invalidURL("Unsupported chain: \(wallet.chain)")
                }
            } catch {
                lastError = error
                SecureLog.info("RPC attempt \(idx) failed for \(wallet.chain): \(error.localizedDescription)")
                continue
            }
        }
        throw lastError
    }

    // MARK: - Token Balances

    /// Fetch ERC-20 token balance via eth_call to balanceOf(address).
    func erc20Balance(tokenContract: String, ownerAddress: String, rpcURL: String) async throws -> String {
        // balanceOf(address) selector = 0x70a08231, address padded to 32 bytes
        let cleanAddr = ownerAddress.hasPrefix("0x") ? String(ownerAddress.dropFirst(2)) : ownerAddress
        let paddedAddress = String(repeating: "0", count: 64 - cleanAddr.count) + cleanAddr
        let callData = "0x70a08231" + paddedAddress

        // eth_call with [{ to, data }, "latest"]
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1,
            "method": "eth_call",
            "params": [["to": tokenContract, "data": callData], "latest"]
        ]
        let jsonBody = try JSONSerialization.data(withJSONObject: body)
        guard let url = URL(string: rpcURL) else { throw BlockchainError.invalidURL(rpcURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)

        struct RPCResult: Decodable {
            let result: String?
        }
        let rpc = try JSONDecoder().decode(RPCResult.self, from: data)
        guard let hex = rpc.result else { return "0" }
        return hexToDecimal(hex)
    }

    /// Fetch multiple ERC-20 token balances.
    func erc20Balances(tokens: [Token], ownerAddress: String, rpcURL: String) async -> [TokenBalance] {
        await withTaskGroup(of: TokenBalance?.self) { group in
            for token in tokens {
                group.addTask {
                    do {
                        let raw = try await self.erc20Balance(
                            tokenContract: token.id,
                            ownerAddress: ownerAddress,
                            rpcURL: rpcURL
                        )
                        guard raw != "0" else { return nil }
                        return TokenBalance(token: token, balance: raw)
                    } catch {
                        return nil
                    }
                }
            }
            var results: [TokenBalance] = []
            for await result in group {
                if let tb = result { results.append(tb) }
            }
            return results.sorted { $0.token.symbol < $1.token.symbol }
        }
    }

    /// Fetch SPL token balances for a Solana address.
    func splTokenBalances(tokens: [Token], ownerAddress: String, rpcURL: String) async -> [TokenBalance] {
        // Use getTokenAccountsByOwner to get all SPL token accounts
        struct TokenAccountResult: Decodable {
            struct Value: Decodable {
                struct Account: Decodable {
                    struct Data: Decodable {
                        struct Parsed: Decodable {
                            struct Info: Decodable {
                                let mint: String
                                struct TokenAmount: Decodable {
                                    let amount: String
                                }
                                let tokenAmount: TokenAmount
                            }
                            let info: Info
                        }
                        let parsed: Parsed
                    }
                    let data: Data
                }
                let account: Account
            }
            let value: [Value]
        }

        do {
            let params: [Any] = [
                ownerAddress,
                ["programId": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"],
                ["encoding": "jsonParsed"]
            ]
            // Manual JSON-RPC call for complex params
            let body: [String: Any] = [
                "jsonrpc": "2.0", "id": 1,
                "method": "getTokenAccountsByOwner",
                "params": params
            ]
            let jsonBody = try JSONSerialization.data(withJSONObject: body)
            guard let url = URL(string: rpcURL) else { return [] }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await session.data(for: request)

            struct RPCWrap: Decodable {
                let result: TokenAccountResult?
            }
            let decoded = try JSONDecoder().decode(RPCWrap.self, from: data)
            guard let accounts = decoded.result?.value else { return [] }

            let tokenMap = Dictionary(uniqueKeysWithValues: tokens.map { ($0.id, $0) })
            return accounts.compactMap { account in
                let mint = account.account.data.parsed.info.mint
                let amount = account.account.data.parsed.info.tokenAmount.amount
                guard let token = tokenMap[mint], amount != "0" else { return nil }
                return TokenBalance(token: token, balance: amount)
            }.sorted { $0.token.symbol < $1.token.symbol }
        } catch {
            SecureLog.error("SPL token balance fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch TRC-20 token balances for a TRON address via TronGrid's
    /// `/v1/accounts/{address}` endpoint. Response includes a `trc20` array
    /// of single-key dicts `{contractAddress: balanceRawString}`.
    ///
    /// Using this convenience endpoint avoids having to base58-decode the
    /// owner address into ABI-encoded hex, which the lower-level
    /// `/wallet/triggerconstantcontract` `balanceOf` call would require.
    func trc20Balances(tokens: [Token], ownerAddress: String, apiURL: String) async -> [TokenBalance] {
        guard !tokens.isEmpty else { return [] }
        let endpoint = "\(apiURL)/v1/accounts/\(ownerAddress)"
        guard let url = URL(string: endpoint) else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            try validateHTTP(response)
            struct Response: Decodable {
                struct Datum: Decodable {
                    // Each element is a single-key {contract: balanceString} dict.
                    let trc20: [[String: String]]?
                }
                let data: [Datum]?
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            // Flatten the list of single-key dicts into one lookup.
            var balances: [String: String] = [:]
            for datum in decoded.data ?? [] {
                for entry in datum.trc20 ?? [] {
                    for (contract, raw) in entry { balances[contract] = raw }
                }
            }
            return tokens.compactMap { token in
                guard let raw = balances[token.id], raw != "0" else { return nil }
                return TokenBalance(token: token, balance: raw)
            }.sorted { $0.token.symbol < $1.token.symbol }
        } catch {
            SecureLog.error("TRC-20 token balance fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch all token balances for a wallet.
    func tokenBalances(for wallet: Wallet, config: NetworkConfig) async -> [TokenBalance] {
        let tokens = TokenList.tokens(for: wallet.chain)
        guard !tokens.isEmpty else { return [] }

        if wallet.chain.isEVM {
            // All EVM chains use ERC-20 semantics. Each chain's token list
            // is routed through the chain-specific RPC so balances read the
            // right ledger.
            return await erc20Balances(tokens: tokens, ownerAddress: wallet.address, rpcURL: config.rpcURL(for: wallet.chain))
        }
        switch wallet.chain {
        case .solana:
            return await splTokenBalances(tokens: tokens, ownerAddress: wallet.address, rpcURL: config.solanaRPC)
        case .tron:
            return await trc20Balances(tokens: tokens, ownerAddress: wallet.address, apiURL: config.tronAPI)
        case .bitcoin, .litecoin:
            // UTXO chains have no token standard.
            return []
        default:
            return []
        }
    }

    // MARK: - Private Helpers

    private struct RPCResponse<T: Decodable>: Decodable {
        let result: T?
        let error: RPCError?
    }
    private struct RPCError: Decodable {
        let code: Int
        let message: String
    }

    private func ethCall<P: Encodable, R: Decodable>(method: String, params: P, rpcURL: String) async throws -> R {
        await waitForSlot()
        defer { releaseSlot() }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
        ]
        // Build request manually to handle heterogeneous params
        var jsonBody = try JSONSerialization.data(withJSONObject: body)
        // Insert params
        let paramsData = try JSONEncoder().encode(params)
        guard var dict = try JSONSerialization.jsonObject(with: jsonBody) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        dict["params"] = try JSONSerialization.jsonObject(with: paramsData)
        jsonBody = try JSONSerialization.data(withJSONObject: dict)

        let url = try Self.validatedURL(rpcURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let capturedRequest = request
        return try await withRetry { [session] in
            let (data, response) = try await session.data(for: capturedRequest)
            guard let http = response as? HTTPURLResponse else {
                throw BlockchainError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw BlockchainError.httpError(statusCode: http.statusCode)
            }
            let rpc = try JSONDecoder().decode(RPCResponse<R>.self, from: data)
            if let error = rpc.error {
                throw BlockchainError.rpcError(code: error.code, message: error.message)
            }
            guard let result = rpc.result else {
                throw BlockchainError.emptyResult
            }
            return result
        }
    }

    /// Variant of `ethCall` that tolerates a `null` result (JSON-RPC pending
    /// responses). Returns nil when the node replies with null rather than
    /// throwing `emptyResult`.
    private func ethCallOptional<P: Encodable, R: Decodable>(method: String, params: P, rpcURL: String) async throws -> R? {
        do {
            let result: R = try await ethCall(method: method, params: params, rpcURL: rpcURL)
            return result
        } catch BlockchainError.emptyResult {
            return nil
        }
    }

    private func solanaCall<P: Encodable, R: Decodable>(method: String, params: P, rpcURL: String) async throws -> R {
        // Solana uses the same JSON-RPC format as Ethereum
        try await ethCall(method: method, params: params, rpcURL: rpcURL)
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BlockchainError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw BlockchainError.httpError(statusCode: http.statusCode)
        }
    }

    private func hexToDecimal(_ hex: String) -> String {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let value = UInt64(clean, radix: 16) else { return "0" }
        return "\(value)"
    }

    private func formatEthBalance(wei: String, symbol: String = "ETH") -> String {
        guard let value = Double(wei) else { return "0 \(symbol)" }
        let eth = value / 1e18
        if eth == 0 { return "0 \(symbol)" }
        if eth < 0.0001 { return String(format: "%.8f \(symbol)", eth) }
        return String(format: "%.4f \(symbol)", eth)
    }

    private func formatBtcBalance(satoshis: UInt64) -> String {
        formatGenericSatoshis(satoshis, symbol: "BTC")
    }

    /// Format an 8-decimal satoshi-like amount with the given ticker. Shared by
    /// Bitcoin and Litecoin (both use 1e8 base units).
    private func formatGenericSatoshis(_ sats: UInt64, symbol: String) -> String {
        let value = Double(sats) / 1e8
        if value == 0 { return "0 \(symbol)" }
        if value < 0.00000001 { return "0 \(symbol)" }
        if value < 0.0001 { return String(format: "%.8f \(symbol)", value) }
        return String(format: "%.4f \(symbol)", value)
    }

    /// Format TRX balance (`sun` = 1e-6 TRX).
    private func formatTronBalance(sun: UInt64) -> String {
        let value = Double(sun) / 1_000_000
        if value == 0 { return "0 TRX" }
        if value < 0.0001 { return String(format: "%.6f TRX", value) }
        return String(format: "%.4f TRX", value)
    }

    private func formatSolBalance(lamports: UInt64) -> String {
        let sol = Double(lamports) / 1e9
        if sol == 0 { return "0 SOL" }
        if sol < 0.0001 { return String(format: "%.9f SOL", sol) }
        return String(format: "%.4f SOL", sol)
    }
}

// MARK: - Fee Estimate Model

struct FeeEstimate {
    let chain: Chain
    let estimatedFee: String
    let feeDetails: String
}

// MARK: - Errors

enum BlockchainError: LocalizedError {
    case rpcError(code: Int, message: String)
    case httpError(statusCode: Int)
    case invalidResponse
    case emptyResult
    case insufficientBalance
    case invalidAddress
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .rpcError(_, let message): return "RPC error: \(message)"
        case .httpError(let code): return "HTTP error: \(code)"
        case .invalidResponse: return "Invalid response from node"
        case .emptyResult: return "Empty result from node"
        case .insufficientBalance: return "Insufficient balance"
        case .invalidAddress: return "Invalid address"
        case .invalidURL(let url): return "Invalid URL: \(url)"
        }
    }

    /// Whether this error is transient and worth retrying.
    var isTransient: Bool {
        switch self {
        case .httpError(let code): return code >= 500 || code == 429
        case .rpcError(let code, _): return code == -32005 // rate limited
        case .invalidResponse, .emptyResult: return true
        default: return false
        }
    }
}
