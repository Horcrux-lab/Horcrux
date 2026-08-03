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
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .resourceUnavailable].contains(error.code) {
                lastError = error
            } catch {
                // Surface the real error for diagnostics, then give up.
                SecureLog.warning("RPC non-retryable error: \(type(of: error)) \(error.localizedDescription)")
                throw error
            }
            let baseDelay: UInt64 = 500_000_000 // 500ms
            let jitter = UInt64.random(in: 0...200_000_000)
            let delay = baseDelay * UInt64(1 << attempt) + jitter
            try? await Task.sleep(nanoseconds: delay)
            let detail = (lastError as? URLError).map { "URLError.\($0.code.rawValue)" }
                ?? (lastError.map { "\(type(of: $0)): \($0.localizedDescription)" } ?? "unknown")
            SecureLog.warning("RPC retry \(attempt + 1)/\(maxRetries) after \(detail)")
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

    /// A Bitcoin txid is exactly 32 bytes of hex. Enforcing that before
    /// interpolating it into a request path stops a value carrying `/`,
    /// `?` or `..` from addressing a different resource, and catches a
    /// truncated hash before it becomes a confusing 404.
    private static func sanitizedTxid(_ txid: String) throws -> String {
        guard txid.count == 64,
              txid.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }) else {
            throw BlockchainError.invalidAddress
        }
        return txid
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
        let gasHex: String
        do {
            gasHex = try await ethCall(
                method: "eth_estimateGas",
                params: estimateParams,
                rpcURL: rpcURL
            )
        } catch {
            // Geth/Infura/Alchemy return "insufficient funds for gas * price
            // + value" from eth_estimateGas when the `from` account can't
            // cover the would-be transaction — even though this is a pure
            // simulation. That error is useless for the UX because it
            // prevents the user from ever *seeing* the fee preview that
            // tells them how much ETH to top up. Retry without `from` so
            // the node runs the call against an address with synthetic
            // funds; the resulting gas limit is still correct for simple
            // transfers. The real balance-vs-fee check happens at submit
            // time, not during preview.
            let lower = error.localizedDescription.lowercased()
            if lower.contains("insufficient funds") || lower.contains("insufficient balance") {
                var txObjNoFrom = txObj
                txObjNoFrom.removeValue(forKey: "from")
                gasHex = try await ethCall(
                    method: "eth_estimateGas",
                    params: [txObjNoFrom],
                    rpcURL: rpcURL
                )
            } else {
                throw error
            }
        }
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

    /// Render a display-ready fee preview from an already-computed
    /// `EvmGasEstimate`. Preferred over `ethFeeEstimateDisplay(from:to:…)`
    /// whenever the caller has just run `ethEstimateGas` — reusing the
    /// estimate saves ~4 RPC round-trips (nonce + estimateGas + gasPrice +
    /// maxPriorityFeePerGas) per compose, which used to double-bill the
    /// user's Alchemy/Infura plan and stall compose UI on slow networks.
    func ethFeeEstimateDisplay(fromEstimate gas: EvmGasEstimate, symbol: String = "ETH") -> FeeEstimate {
        let maxFeeWei = Decimal(string: gas.maxFeePerGas) ?? 0
        let maxCostWei = Decimal(gas.gasLimit) * maxFeeWei
        let ethCost = maxCostWei / Decimal(1_000_000_000_000_000_000)
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 8
        formatter.minimumFractionDigits = 4
        let formatted = formatter.string(from: ethCost as NSDecimalNumber) ?? "\(ethCost)"
        return FeeEstimate(
            chain: .ethereum,
            estimatedFee: "\(formatted) \(symbol)",
            feeDetails: "Gas: \(gas.gasLimit) × \(gas.maxFeePerGas) wei"
        )
    }

    /// Human-readable fee estimate for display (in ETH). Convenience wrapper
    /// that also runs the gas estimate; prefer `ethFeeEstimateDisplay(fromEstimate:)`
    /// when an `EvmGasEstimate` is already available.
    func ethFeeEstimateDisplay(from: String, to: String, valueWei: String, rpcURL: String) async throws -> FeeEstimate {
        let gas = try await ethEstimateGas(from: from, to: to, valueWei: valueWei, rpcURL: rpcURL)
        return ethFeeEstimateDisplay(fromEstimate: gas)
    }

    /// Broadcast a signed EVM transaction. Returns the tx hash.
    func ethSendRawTransaction(signedTxHex: String, rpcURL: String) async throws -> String {
        try await ethCall(
            method: "eth_sendRawTransaction",
            params: [signedTxHex],
            rpcURL: rpcURL
        )
    }

    /// Broadcast a signed EVM transaction with automatic fallback across
    /// the resolved endpoint list. Returns the tx hash.
    ///
    /// Fallback policy:
    /// - 401/403 (auth failure) → mark cooldown 30min, try next endpoint.
    /// - 5xx/timeout/URLError → rethrow. Tx may already be in the mempool
    ///   on the failing endpoint; auto-switching risks a double-broadcast
    ///   silently bumping the user's nonce. User can retry manually.
    /// - "already known" / "nonce too low" / "insufficient funds" /
    ///   "execution reverted" → business error, rethrow, do not switch.
    func ethSendRawTransaction(signedTxHex: String, chain: Chain, config: NetworkConfig) async throws -> String {
        let attempts = RPCFallbacks.resolvedAttempts(for: chain, config: config)
        guard !attempts.isEmpty else { throw BlockchainError.invalidURL("no endpoints") }
        var lastError: Error = BlockchainError.invalidURL("no endpoints")
        for (idx, url) in attempts.enumerated() {
            do {
                let hash = try await ethSendRawTransaction(signedTxHex: signedTxHex, rpcURL: url)
                RPCEndpointHealth.markOk(url)
                if idx > 0 { SecureLog.info("ethSendRaw fallback #\(idx) succeeded on \(URL(string: url)?.host ?? "?")") }
                return hash
            } catch {
                lastError = error
                switch Self.classifyForFallback(error) {
                case .authFailure:
                    RPCEndpointHealth.markAuthFailed(url)
                    SecureLog.warning("ethSendRaw auth-failed on \(URL(string: url)?.host ?? "?"); trying next")
                    continue
                case .businessError, .transient:
                    // Never auto-switch on business or transient errors —
                    // the tx may already be in some mempool.
                    throw error
                }
            }
        }
        throw lastError
    }

    // MARK: - RPC fallback plumbing (fault-aware routing)

    enum FallbackClassification {
        /// 401/403 or -32000 Unauthorized: endpoint's key is missing/revoked.
        case authFailure
        /// 5xx, timeouts, URLErrors, -32601 method not found, invalidResponse.
        case transient
        /// User-space errors that must surface to the caller unchanged.
        case businessError
    }

    static func classifyForFallback(_ error: Error) -> FallbackClassification {
        if let be = error as? BlockchainError {
            switch be {
            case .httpError(let code):
                if code == 401 || code == 403 { return .authFailure }
                return .transient
            case .rpcError(let code, let message):
                let lower = message.lowercased()
                if lower.contains("unauthorized") || lower.contains("api key")
                    || lower.contains("forbidden") || lower.contains("invalid project") {
                    return .authFailure
                }
                if lower.contains("insufficient funds") || lower.contains("insufficient balance")
                    || lower.contains("execution reverted") || lower.contains("nonce too low")
                    || lower.contains("already known") || lower.contains("replacement transaction underpriced")
                    || lower.contains("gas required exceeds") || lower.contains("intrinsic gas too low")
                    || lower.contains("transaction underpriced") || lower.contains("known transaction") {
                    return .businessError
                }
                if code == -32601 { return .transient } // method not found on limited tier
                return .transient
            case .emptyResult, .invalidAddress, .insufficientBalance:
                return .businessError
            case .invalidResponse, .invalidURL:
                return .transient
            }
        }
        return .transient
    }

    /// Run a block against the resolved endpoint list, switching URL on
    /// auth and transient failures. Business errors abort immediately.
    ///
    /// The closure receives one URL per attempt and should perform a
    /// single RPC call (or a tight cluster of them if you need multi-call
    /// consistency on a single endpoint — see `ethEstimateGas(chain:config:)`).
    private func withFallbackURL<T>(
        chain: Chain,
        config: NetworkConfig,
        classify: (Error) -> FallbackClassification = BlockchainService.classifyForFallback,
        op: (_ url: String) async throws -> T
    ) async throws -> T {
        let attempts = RPCFallbacks.resolvedAttempts(for: chain, config: config)
        guard !attempts.isEmpty else { throw BlockchainError.invalidURL("no endpoints") }
        var lastError: Error = BlockchainError.invalidURL("no endpoints")
        for (idx, url) in attempts.enumerated() {
            do {
                let result = try await op(url)
                RPCEndpointHealth.markOk(url)
                if idx > 0 { SecureLog.info("RPC fallback #\(idx) succeeded on \(URL(string: url)?.host ?? "?")") }
                #if DEBUG
                SecureLog.debug("RPC routed via \(RPCProvider.identify(url).label.isEmpty ? (URL(string: url)?.host ?? "?") : RPCProvider.identify(url).label) [\(URL(string: url)?.host ?? "?")]")
                #endif
                return result
            } catch {
                lastError = error
                switch classify(error) {
                case .authFailure:
                    RPCEndpointHealth.markAuthFailed(url)
                    SecureLog.warning("RPC auth-failed on \(URL(string: url)?.host ?? "?"); cooling 30min")
                    continue
                case .transient:
                    RPCEndpointHealth.markTransientFailed(url)
                    SecureLog.info("RPC transient error on \(URL(string: url)?.host ?? "?"): \(error.localizedDescription); trying next")
                    continue
                case .businessError:
                    throw error
                }
            }
        }
        throw lastError
    }

    /// Fault-aware EVM gas estimate. Uses a single resolved endpoint for
    /// the whole quartet (nonce + estimateGas + gasPrice + priorityFee)
    /// so the returned estimate is internally consistent; if that
    /// endpoint fails on any sub-call, the whole group re-runs against
    /// the next candidate.
    func ethEstimateGas(from: String, to: String, valueWei: String, data txData: String? = nil, chain: Chain, config: NetworkConfig) async throws -> EvmGasEstimate {
        return try await withFallbackURL(chain: chain, config: config) { url in
            try await ethEstimateGas(from: from, to: to, valueWei: valueWei, data: txData, rpcURL: url)
        }
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

    /// Fault-aware UTXO fetch. Walks the resolved endpoint list with the
    /// same cooldown filtering and health reporting as every other routed
    /// call.
    ///
    /// This is the first call in `SigningViewModel.buildP2WPKHSignHash`, so
    /// without it a single unreachable Esplora host makes it impossible to
    /// build any transaction — which is exactly what happened when
    /// `blockstream.info`, the primary, went dark on 2026-07-31 while
    /// `mempool.space` sat healthy behind it.
    func btcUtxos(address: String, chain: Chain, config: NetworkConfig) async throws -> [BtcUtxo] {
        return try await withFallbackURL(chain: chain, config: config) { url in
            try await btcUtxos(address: address, apiURL: url)
        }
    }

    /// A previously-broadcast transaction, as Esplora reports it.
    ///
    /// Only the fields a replacement needs are decoded: which outpoints it
    /// spends (so the replacement can spend the same ones and therefore
    /// actually conflict), what it paid (BIP-125 rule 4), whether each
    /// input signalled replaceability, and whether it is still in the
    /// mempool at all.
    struct BtcTx: Decodable, Sendable, Equatable {
        struct Prevout: Decodable, Sendable, Equatable {
            let scriptpubkey: String
            let value: UInt64
        }
        struct Vin: Decodable, Sendable, Equatable {
            let txid: String
            let vout: UInt32
            /// Absent on coinbase inputs, and on deployments that do not
            /// serve prevouts. Without it there is no value to spend.
            let prevout: Prevout?
            /// Optional so a deployment that omits it is treated as
            /// "cannot prove opt-in" rather than failing to decode the
            /// whole response.
            let sequence: UInt32?
        }
        struct Status: Decodable, Sendable, Equatable {
            let confirmed: Bool
        }
        let txid: String
        let vin: [Vin]
        let fee: UInt64
        let status: Status
    }

    /// Fetch a transaction by txid.
    func btcTx(txid: String, apiURL: String) async throws -> BtcTx {
        let safe = try Self.sanitizedTxid(txid)
        let url = try Self.validatedURL("\(apiURL)/tx/\(safe)")
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        return try JSONDecoder().decode(BtcTx.self, from: data)
    }

    /// Fault-aware transaction fetch, on the same fallback list as the
    /// UTXO, fee and broadcast calls.
    func btcTx(txid: String, chain: Chain, config: NetworkConfig) async throws -> BtcTx {
        return try await withFallbackURL(chain: chain, config: config) { url in
            try await btcTx(txid: txid, apiURL: url)
        }
    }

    /// Fetch recommended fee rates (sat/vB).
    struct BtcFeeEstimate: Decodable {
        let fastestFee: UInt64
        let halfHourFee: UInt64
        let hourFee: UInt64
        let minimumFee: UInt64
    }

    /// `/v1/fees/recommended` is a mempool.space extension rather than part
    /// of Esplora. mempool.space and litecoinspace.org both serve it —
    /// verified live, and litecoinspace.org answers 404 for Esplora's own
    /// `/fee-estimates`, so this is not interchangeable — while
    /// blockstream.info does not, hence the redirect.
    ///
    /// The redirect means that under the shipped Bitcoin table both
    /// endpoints resolve to the same host for fees, so
    /// `btcFeeEstimate(chain:config:)` buys no redundancy for a user on the
    /// defaults. It buys real redundancy for a user whose primary is their
    /// own Esplora, and either way the caller no longer silently prices a
    /// transaction when nothing answers. Making blockstream an independent
    /// fee source needs its `/fee-estimates` shape implemented and tested
    /// against the live host, which is a separate change.
    func btcFeeEstimate(apiURL: String) async throws -> BtcFeeEstimate {
        let feeURLString = apiURL.contains("blockstream")
            ? "https://mempool.space/api/v1/fees/recommended"
            : "\(apiURL)/v1/fees/recommended"
        let url = try Self.validatedURL(feeURLString)
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        return try JSONDecoder().decode(BtcFeeEstimate.self, from: data)
    }

    /// Fault-aware fee estimate.
    ///
    /// The signing path used to call `btcFeeEstimate(apiURL:)` against the
    /// single configured primary and swallow the error with `try?`, landing
    /// on a 2 sat/vB floor. That was survivable only while the UTXO fetch
    /// used the same URL and threw first, aborting the build. Now that the
    /// UTXO fetch and the broadcast fail over, a dead primary would stop
    /// blocking the send and start silently pricing it at the floor — and
    /// the builder writes nSequence 0xFFFF_FFFE, so the resulting stuck
    /// transaction is not BIP125-replaceable either.
    func btcFeeEstimate(chain: Chain, config: NetworkConfig) async throws -> BtcFeeEstimate {
        return try await withFallbackURL(chain: chain, config: config) { url in
            try await btcFeeEstimate(apiURL: url)
        }
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

    /// How a failed Esplora broadcast should be treated, which is not how
    /// `classifyForFallback` would treat it.
    ///
    /// Esplora rejects an invalid transaction with HTTP 400 and a reason
    /// such as `bad-txns-inputs-missingorspent`. The generic classifier maps
    /// every non-401/403 HTTP error to `.transient`, which for a broadcast
    /// would be doubly wrong: the transaction would be re-submitted to every
    /// endpoint in turn, each rejecting it identically, *and* each of those
    /// perfectly healthy endpoints would be marked failed. `RPCEndpointHealth`
    /// is shared with balance fetches and confirmation polling, so one bad
    /// transaction would degrade routing for the whole app.
    ///
    /// So a 4xx from the node is a verdict on the transaction, not on the
    /// endpoint, and must surface unchanged — but only the codes that
    /// actually carry a verdict. 404/405/407 say "this endpoint does not
    /// serve this route", which is an endpoint fault and exactly what
    /// failover is for: per-chain overrides are stored without URL-shape
    /// validation, so a Bitcoin override missing its `/api` suffix 404s on
    /// `POST /tx` while balances and the UTXO fetch quietly fail over and
    /// keep working. Treating that as a verdict would leave the wallet
    /// displaying balances, building transactions, and unable to send, with
    /// the failover machinery declining by design.
    ///
    /// The other exceptions are 401/403 (our credentials, not the
    /// transaction), and 408/429 (the node never formed a verdict).
    static func classifyBtcBroadcastForFallback(_ error: Error) -> FallbackClassification {
        guard case .httpError(let code)? = error as? BlockchainError else {
            // Transport failures — the case that matters here, since an
            // unreachable host never saw the transaction at all.
            return .transient
        }
        if code == 401 || code == 403 { return .authFailure }
        // Esplora rejects an invalid transaction with 400; 422 is the other
        // code an Esplora-compatible host may use to say the same thing.
        if code == 400 || code == 422 { return .businessError }
        return .transient
    }

    /// Fault-aware broadcast. Returns the txid.
    ///
    /// Unlike `ethSendRawTransaction(signedTxHex:chain:config:)`, this does
    /// fail over on transport errors. That policy exists on the EVM side
    /// because a re-submission could bump the user's nonce; a fully signed
    /// Bitcoin transaction has a fixed txid, so submitting it to a second
    /// Esplora host cannot create a second transaction — at worst the second
    /// host answers that it already knows it. Refusing to fail over would
    /// mean an unreachable primary blocks sending entirely, which is the
    /// failure this exists to prevent.
    func btcBroadcast(signedTxHex: String, chain: Chain, config: NetworkConfig) async throws -> String {
        return try await withFallbackURL(
            chain: chain,
            config: config,
            classify: Self.classifyBtcBroadcastForFallback
        ) { url in
            try await btcBroadcast(signedTxHex: signedTxHex, apiURL: url)
        }
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

    /// Fetch the chain id the remote RPC claims, decoded from its hex-encoded
    /// `eth_chainId` response. Used by the settings page to catch URL/network
    /// mismatches (e.g. a Sepolia RPC configured under a Mainnet selector).
    func ethChainId(rpcURL: String) async throws -> UInt64 {
        let hex: String = try await ethCall(
            method: "eth_chainId",
            params: [] as [String],
            rpcURL: rpcURL
        )
        let stripped = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return UInt64(stripped, radix: 16) ?? 0
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
        throw BlockchainError.rpcError(code: 0, message: "\(code): \(msg)")
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
            throw BlockchainError.rpcError(code: 0, message: err)
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

    /// Fetch the native-asset balance, routed through the fault-aware
    /// fallback helper so this path gets the same cooldown filtering and
    /// health reporting as every other RPC call. It previously walked
    /// `orderedAttempts` by hand without either, which meant the app's
    /// single hottest read path re-tried known-dead endpoints on every
    /// refresh and never fed results back into the health registry.
    func balance(for wallet: Wallet, config: NetworkConfig) async throws -> String {
        // Reject unsupported chains up front. Discovering this inside the
        // loop would walk every endpoint to reach the same conclusion,
        // burning latency and marking healthy endpoints as failures.
        switch wallet.chain {
        case .bitcoin, .litecoin, .solana, .tron:
            break
        default:
            guard wallet.chain.isEVM else {
                throw BlockchainError.invalidURL("Unsupported chain: \(wallet.chain)")
            }
        }

        return try await withFallbackURL(chain: wallet.chain, config: config) { url in
            if wallet.chain.isEVM {
                let wei = try await ethBalance(address: wallet.address, rpcURL: url)
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
                return formatBtcBalance(satoshis: sats)
            case .litecoin:
                // litecoinspace.org exposes the Esplora API, same shape as Blockstream.
                let litoshi = try await btcBalance(address: wallet.address, apiURL: url)
                return formatGenericSatoshis(litoshi, symbol: "LTC")
            case .solana:
                let lamports = try await solBalance(address: wallet.address, rpcURL: url)
                return formatSolBalance(lamports: lamports)
            case .tron:
                let sun = try await tronBalance(address: wallet.address, apiURL: url)
                return formatTronBalance(sun: sun)
            default:
                throw BlockchainError.invalidURL("Unsupported chain: \(wallet.chain)")
            }
        }
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

    /// ERC-20 metadata lookup helper (name / symbol / decimals).
    /// Used by the "Add custom token" form autofill.
    struct ERC20Metadata { let symbol: String; let name: String; let decimals: UInt8 }
    func erc20Metadata(contract: String, rpcURL: String) async throws -> ERC20Metadata {
        func call(selector: String) async throws -> String {
            let body: [String: Any] = [
                "jsonrpc": "2.0", "id": 1,
                "method": "eth_call",
                "params": [["to": contract, "data": selector], "latest"]
            ]
            let jsonBody = try JSONSerialization.data(withJSONObject: body)
            guard let url = URL(string: rpcURL) else { throw BlockchainError.invalidURL(rpcURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            try validateHTTP(response)
            struct R: Decodable { let result: String? }
            return (try JSONDecoder().decode(R.self, from: data)).result ?? "0x"
        }
        // ABI string return layout: 32-byte offset | 32-byte length | data.
        func decodeAbiString(_ hex: String) -> String {
            var h = hex
            if h.hasPrefix("0x") { h = String(h.dropFirst(2)) }
            guard h.count >= 128 else {
                // Fallback: bytes32 short strings.
                return bytes32ToString(h)
            }
            let lenHex = String(h.dropFirst(64).prefix(64))
            guard let len = UInt64(lenHex, radix: 16), len > 0 else { return bytes32ToString(h) }
            let payload = h.dropFirst(128).prefix(Int(len) * 2)
            return hexToUTF8(String(payload))
        }
        func bytes32ToString(_ h: String) -> String {
            // Trim trailing zeros, decode ascii.
            var bytes = [UInt8]()
            var i = h.startIndex
            while i < h.endIndex {
                let next = h.index(i, offsetBy: 2, limitedBy: h.endIndex) ?? h.endIndex
                if let b = UInt8(h[i..<next], radix: 16), b != 0 { bytes.append(b) }
                i = next
            }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
        func hexToUTF8(_ h: String) -> String {
            var bytes = [UInt8]()
            var i = h.startIndex
            while i < h.endIndex {
                let next = h.index(i, offsetBy: 2, limitedBy: h.endIndex) ?? h.endIndex
                if let b = UInt8(h[i..<next], radix: 16) { bytes.append(b) }
                i = next
            }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
        // symbol() = 0x95d89b41, name() = 0x06fdde03, decimals() = 0x313ce567.
        async let sym = call(selector: "0x95d89b41")
        async let nm = call(selector: "0x06fdde03")
        async let dec = call(selector: "0x313ce567")
        let (symHex, nameHex, decHex) = try await (sym, nm, dec)
        let decimalsInt = UInt64(decHex.hasPrefix("0x") ? String(decHex.dropFirst(2)) : decHex, radix: 16) ?? 18
        return ERC20Metadata(
            symbol: decodeAbiString(symHex).trimmingCharacters(in: .whitespacesAndNewlines),
            name: decodeAbiString(nameHex).trimmingCharacters(in: .whitespacesAndNewlines),
            decimals: UInt8(min(decimalsInt, 36))
        )
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

    /// Fetch all token balances for a wallet. Pass `extraTokens` to include
    /// user-added custom tokens in addition to the built-in `TokenList`.
    func tokenBalances(for wallet: Wallet, config: NetworkConfig, extraTokens: [Token] = []) async -> [TokenBalance] {
        var tokens = TokenList.tokens(for: wallet.chain)
        let known = Set(tokens.map { $0.id.lowercased() })
        for t in extraTokens where t.chain == wallet.chain && !known.contains(t.id.lowercased()) {
            tokens.append(t)
        }
        guard !tokens.isEmpty else { return [] }

        if wallet.chain.isEVM {
            // All EVM chains use ERC-20 semantics. Each chain's token list
            // is routed through the chain-specific RPC so balances read the
            // right ledger.
            return await erc20Balances(tokens: tokens, ownerAddress: wallet.address, rpcURL: config.rpcURL(for: wallet.chain))
        }
        switch wallet.chain {
        case .solana:
            return await splTokenBalances(tokens: tokens, ownerAddress: wallet.address, rpcURL: config.rpcURL(for: wallet.chain))
        case .tron:
            return await trc20Balances(tokens: tokens, ownerAddress: wallet.address, apiURL: config.rpcURL(for: wallet.chain))
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

    // MARK: - Transaction history sync

    /// Light-weight external transaction summary used by the history syncer.
    /// Amounts are in smallest units (sats / SUN / lamports / wei) represented
    /// as `Decimal` to survive the 256-bit range wei values can reach; sign
    /// indicates direction (positive = received, negative = sent).
    struct ExternalTx {
        let txHash: String
        let blockTime: Date?
        let from: String
        let to: String
        let deltaSmallest: Decimal
        let feeSmallest: Decimal
        let confirmed: Bool
    }

    /// Fetch the most recent Esplora-style transactions (Blockstream for BTC,
    /// litecoinspace.org for LTC). Returns at most 25 items.
    func esploraRecentTxs(address: String, apiURL: String) async throws -> [ExternalTx] {
        let safe = try Self.sanitizedAddress(address)
        let url = try Self.validatedURL("\(apiURL)/address/\(safe)/txs")
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        struct Vin: Decodable {
            let prevout: Prevout?
            struct Prevout: Decodable {
                let scriptpubkey_address: String?
                let value: UInt64?
            }
        }
        struct Vout: Decodable {
            let scriptpubkey_address: String?
            let value: UInt64
        }
        struct Status: Decodable {
            let confirmed: Bool
            let block_time: Int64?
        }
        struct Tx: Decodable {
            let txid: String
            let vin: [Vin]
            let vout: [Vout]
            let fee: UInt64
            let status: Status
        }
        let txs = try JSONDecoder().decode([Tx].self, from: data)
        let safeLower = safe.lowercased()
        return txs.prefix(25).map { tx in
            // Net delta for this address = sum(vout to me) - sum(vin from me).
            let sentIn = tx.vin.reduce(0) { acc, v in
                (v.prevout?.scriptpubkey_address?.lowercased() == safeLower) ? acc + (v.prevout?.value ?? 0) : acc
            }
            let receivedOut = tx.vout.reduce(0) { acc, v in
                (v.scriptpubkey_address?.lowercased() == safeLower) ? acc + v.value : acc
            }
            let delta = Int64(receivedOut) - Int64(sentIn)
            // Best-effort counterparty: if we sent, pick the first vout not ours;
            // if we received, pick the first vin.prevout not ours.
            let counterparty: String = {
                if delta < 0 {
                    return tx.vout.first(where: { $0.scriptpubkey_address?.lowercased() != safeLower })?.scriptpubkey_address ?? ""
                } else {
                    return tx.vin.first(where: { $0.prevout?.scriptpubkey_address?.lowercased() != safeLower })?.prevout?.scriptpubkey_address ?? ""
                }
            }()
            return ExternalTx(
                txHash: tx.txid,
                blockTime: tx.status.block_time.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                from: delta < 0 ? safe : counterparty,
                to: delta < 0 ? counterparty : safe,
                deltaSmallest: Decimal(delta),
                feeSmallest: Decimal(tx.fee),
                confirmed: tx.status.confirmed
            )
        }
    }

    /// Fetch recent TRON transactions via TronGrid's keyless v1 endpoint.
    /// Returns native TRX transfers only (TransferContract); TRC-20 history
    /// lives at `/v1/accounts/{addr}/transactions/trc20`.
    func tronRecentTxs(address: String, apiURL: String) async throws -> [ExternalTx] {
        let safe = try Self.sanitizedAddress(address)
        let url = try Self.validatedURL("\(apiURL)/v1/accounts/\(safe)/transactions?limit=25&only_confirmed=true")
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else {
            return []
        }
        var out: [ExternalTx] = []
        for tx in rows {
            guard let txId = tx["txID"] as? String,
                  let rawData = tx["raw_data"] as? [String: Any],
                  let contracts = rawData["contract"] as? [[String: Any]],
                  let first = contracts.first,
                  (first["type"] as? String) == "TransferContract",
                  let paramWrap = first["parameter"] as? [String: Any],
                  let value = paramWrap["value"] as? [String: Any],
                  let fromHex = value["owner_address"] as? String,
                  let toHex = value["to_address"] as? String,
                  let amount = value["amount"] as? NSNumber
            else { continue }
            let ts = (tx["block_timestamp"] as? NSNumber)?.doubleValue ?? 0
            let ret = tx["ret"] as? [[String: Any]]
            let ok = (ret?.first?["contractRet"] as? String) == "SUCCESS"
            let feeRaw = (tx["net_fee"] as? NSNumber)?.uint64Value ?? 0
            let from = tronHexAddrToBase58(fromHex) ?? fromHex
            let to = tronHexAddrToBase58(toHex) ?? toHex
            let isSend = from.lowercased() == safe.lowercased()
            out.append(ExternalTx(
                txHash: txId,
                blockTime: ts > 0 ? Date(timeIntervalSince1970: ts / 1000) : nil,
                from: from,
                to: to,
                deltaSmallest: isSend ? Decimal(-amount.int64Value) : Decimal(amount.int64Value),
                feeSmallest: Decimal(feeRaw),
                confirmed: ok
            ))
        }
        return out
    }

    /// Fetch recent EVM transactions via Etherscan V2's unified multichain
    /// endpoint. `chainId` must match the active EVM network (1=mainnet,
    /// 137=Polygon, 56=BNB, etc.). Without an API key the free tier is
    /// rate-limited to ~1 req / 5s but usable.
    func etherscanRecentTxs(address: String, chainId: UInt64, apiKey: String) async throws -> [ExternalTx] {
        let safe = try Self.sanitizedAddress(address)
        var comps = URLComponents(string: "https://api.etherscan.io/v2/api")!
        var items = [
            URLQueryItem(name: "chainid", value: "\(chainId)"),
            URLQueryItem(name: "module", value: "account"),
            URLQueryItem(name: "action", value: "txlist"),
            URLQueryItem(name: "address", value: safe),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "offset", value: "25"),
            URLQueryItem(name: "sort", value: "desc"),
        ]
        if !apiKey.isEmpty {
            items.append(URLQueryItem(name: "apikey", value: apiKey))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw BlockchainError.invalidURL(comps.string ?? "") }
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        // Etherscan returns status="0" + result as string "No transactions found"
        // for fresh addresses. Treat as empty list, not error.
        guard let result = json["result"] as? [[String: Any]] else {
            return []
        }
        var out: [ExternalTx] = []
        let safeLower = safe.lowercased()
        for row in result {
            guard let hash = row["hash"] as? String,
                  let from = row["from"] as? String,
                  let to = row["to"] as? String,
                  let valueStr = row["value"] as? String,
                  let value = Decimal(string: valueStr)
            else { continue }
            let gasUsedStr = row["gasUsed"] as? String ?? "0"
            let gasPriceStr = row["gasPrice"] as? String ?? "0"
            let feeWei: Decimal = {
                guard let g = Decimal(string: gasUsedStr), let p = Decimal(string: gasPriceStr) else { return 0 }
                return g * p
            }()
            let tsStr = row["timeStamp"] as? String ?? "0"
            let ts = TimeInterval(tsStr) ?? 0
            let isSend = from.lowercased() == safeLower
            let err = (row["isError"] as? String) == "1"
            out.append(ExternalTx(
                txHash: hash,
                blockTime: ts > 0 ? Date(timeIntervalSince1970: ts) : nil,
                from: from,
                to: to,
                deltaSmallest: isSend ? -value : value,
                feeSmallest: feeWei,
                confirmed: !err
            ))
        }
        return out
    }

    /// Fetch recent ERC-20 token transfers for an address via Etherscan V2.
    /// Returns tuples of (delta, symbol, decimals, contract) analogous to
    /// `tronRecentTrc20Txs`.
    func etherscanRecentTokenTxs(address: String, chainId: UInt64, apiKey: String) async throws
        -> [(ExternalTx, String, Int, String)]
    {
        let safe = try Self.sanitizedAddress(address)
        var comps = URLComponents(string: "https://api.etherscan.io/v2/api")!
        var items = [
            URLQueryItem(name: "chainid", value: "\(chainId)"),
            URLQueryItem(name: "module", value: "account"),
            URLQueryItem(name: "action", value: "tokentx"),
            URLQueryItem(name: "address", value: safe),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "offset", value: "25"),
            URLQueryItem(name: "sort", value: "desc"),
        ]
        if !apiKey.isEmpty {
            items.append(URLQueryItem(name: "apikey", value: apiKey))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw BlockchainError.invalidURL(comps.string ?? "") }
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else { return [] }
        var out: [(ExternalTx, String, Int, String)] = []
        let safeLower = safe.lowercased()
        for row in result {
            guard let hash = row["hash"] as? String,
                  let from = row["from"] as? String,
                  let to = row["to"] as? String,
                  let valueStr = row["value"] as? String,
                  let value = Decimal(string: valueStr),
                  let symbol = row["tokenSymbol"] as? String,
                  let contract = row["contractAddress"] as? String
            else { continue }
            let decStr = row["tokenDecimal"] as? String ?? "18"
            let decimals = Int(decStr) ?? 18
            let tsStr = row["timeStamp"] as? String ?? "0"
            let ts = TimeInterval(tsStr) ?? 0
            let isSend = from.lowercased() == safeLower
            let ext = ExternalTx(
                txHash: hash,
                blockTime: ts > 0 ? Date(timeIntervalSince1970: ts) : nil,
                from: from,
                to: to,
                deltaSmallest: isSend ? -value : value,
                feeSmallest: 0,
                confirmed: true
            )
            out.append((ext, symbol, decimals, contract))
        }
        return out
    }
    /// `getSignaturesForAddress` to list signatures then one
    /// `getTransaction` per signature to compute the pre/post lamport
    /// delta for the target account.
    func solanaRecentTxs(address: String, rpcURL: String, limit: Int = 10) async throws -> [ExternalTx] {
        let safe = try Self.sanitizedAddress(address)
        let sigsBody: [String: Any] = [
            "jsonrpc": "2.0", "id": 1,
            "method": "getSignaturesForAddress",
            "params": [safe, ["limit": limit]],
        ]
        let sigsData = try await rpcCall(url: rpcURL, body: sigsBody)
        guard let sigsJson = try JSONSerialization.jsonObject(with: sigsData) as? [String: Any],
              let sigs = sigsJson["result"] as? [[String: Any]] else {
            return []
        }
        var results: [ExternalTx] = []
        for sigEntry in sigs {
            guard let signature = sigEntry["signature"] as? String else { continue }
            let blockTime = (sigEntry["blockTime"] as? NSNumber)?.doubleValue
            let failed = sigEntry["err"] as? NSNull == nil && sigEntry["err"] != nil
            let txBody: [String: Any] = [
                "jsonrpc": "2.0", "id": 1,
                "method": "getTransaction",
                "params": [signature, ["encoding": "json", "maxSupportedTransactionVersion": 0]],
            ]
            let txData = try await rpcCall(url: rpcURL, body: txBody)
            guard let txJson = try JSONSerialization.jsonObject(with: txData) as? [String: Any],
                  let result = txJson["result"] as? [String: Any],
                  let meta = result["meta"] as? [String: Any],
                  let tx = result["transaction"] as? [String: Any],
                  let msg = tx["message"] as? [String: Any],
                  let accounts = msg["accountKeys"] as? [String],
                  let pre = meta["preBalances"] as? [NSNumber],
                  let post = meta["postBalances"] as? [NSNumber],
                  let idx = accounts.firstIndex(of: safe),
                  idx < pre.count, idx < post.count
            else { continue }
            let delta = post[idx].int64Value - pre[idx].int64Value
            let fee = (meta["fee"] as? NSNumber)?.uint64Value ?? 0
            // Counterparty: first non-self account key that's not a program.
            let other = accounts.first { $0 != safe } ?? ""
            results.append(ExternalTx(
                txHash: signature,
                blockTime: blockTime.map { Date(timeIntervalSince1970: $0) },
                from: delta < 0 ? safe : other,
                to: delta < 0 ? other : safe,
                deltaSmallest: Decimal(delta),
                feeSmallest: Decimal(fee),
                confirmed: !failed
            ))
        }
        return results
    }

    private func rpcCall(url: String, body: [String: Any]) async throws -> Data {
        guard let u = URL(string: url) else { throw BlockchainError.invalidURL(url) }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        try validateHTTP(response)
        return data
    }

    /// Fetch recent TRC-20 token transfers for a TRON address via TronGrid's
    /// /v1/accounts/{addr}/transactions/trc20 endpoint. Returns rows as
    /// ExternalTx with the token symbol embedded in the hash prefix so the
    /// UI syncer can show e.g. 'USDT' amounts instead of raw SUN.
    func tronRecentTrc20Txs(address: String, apiURL: String) async throws -> [(ExternalTx, tokenSymbol: String, decimals: Int, contract: String)] {
        let safe = try Self.sanitizedAddress(address)
        let url = try Self.validatedURL("\(apiURL)/v1/accounts/\(safe)/transactions/trc20?limit=25&only_confirmed=true")
        let (data, response) = try await session.data(from: url)
        try validateHTTP(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else {
            return []
        }
        var out: [(ExternalTx, tokenSymbol: String, decimals: Int, contract: String)] = []
        for tx in rows {
            guard let txId = tx["transaction_id"] as? String,
                  let from = tx["from"] as? String,
                  let to = tx["to"] as? String,
                  let valueStr = tx["value"] as? String,
                  let value = Decimal(string: valueStr),
                  let tokenInfo = tx["token_info"] as? [String: Any],
                  let symbol = tokenInfo["symbol"] as? String,
                  let decimals = (tokenInfo["decimals"] as? NSNumber)?.intValue,
                  let contract = tokenInfo["address"] as? String
            else { continue }
            let ts = (tx["block_timestamp"] as? NSNumber)?.doubleValue ?? 0
            let isSend = from.lowercased() == safe.lowercased()
            let ext = ExternalTx(
                txHash: txId,
                blockTime: ts > 0 ? Date(timeIntervalSince1970: ts / 1000) : nil,
                from: from,
                to: to,
                deltaSmallest: isSend ? -value : value,
                feeSmallest: 0,
                confirmed: true
            )
            out.append((ext, tokenSymbol: symbol, decimals: decimals, contract: contract))
        }
        return out
    }

    /// Convert a TRON hex address (41XX…) back to base58. Uses the same
    /// base58check + 0x41 network-byte scheme as tronBase58AddressToHex20 in
    /// reverse.
    private func tronHexAddrToBase58(_ hex: String) -> String? {
        let clean = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard clean.count == 42 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(21)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Base58Check.encode(Data(bytes))
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
    ///
    /// `.emptyResult` is intentionally **not** transient: a JSON-RPC `null`
    /// result is a legitimate "not yet available" reply — a pending
    /// `eth_getTransactionReceipt`, an unset storage slot, a block that
    /// hasn't propagated — not a network error. Retrying it three times
    /// per call produced ~6-9s retry storms against public endpoints that
    /// starved other concurrent RPC calls (e.g. the nonce/gas fetch a
    /// freshly-tapped "Sign" button needs) of URLSession connection
    /// slots. Callers that want to tolerate null go through
    /// `ethCallOptional`, which catches `.emptyResult` and returns nil.
    var isTransient: Bool {
        switch self {
        case .httpError(let code): return code >= 500 || code == 429
        case .rpcError(let code, _): return code == -32005 // rate limited
        case .invalidResponse: return true
        default: return false
        }
    }
}
