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
        // Use certificate-pinned session by default
        self.session = session ?? PinnedURLSession.shared.session
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
        let maxCostWei = gas.gasLimit * (UInt64(gas.maxFeePerGas) ?? 0)
        let ethCost = Decimal(maxCostWei) / Decimal(1_000_000_000_000_000_000)
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
        try await solanaCall(
            method: "sendTransaction",
            params: [signedTxBase64, ["encoding": "base64"]],
            rpcURL: rpcURL
        )
    }

    // MARK: - Generic balance fetch

    func balance(for wallet: Wallet, config: NetworkConfig) async throws -> String {
        switch wallet.chain {
        case .ethereum:
            let wei = try await ethBalance(address: wallet.address, rpcURL: config.ethereumRPC)
            return formatEthBalance(wei: wei)
        case .bitcoin:
            let sats = try await btcBalance(address: wallet.address, apiURL: config.bitcoinAPI)
            return formatBtcBalance(satoshis: sats)
        case .solana:
            let lamports = try await solBalance(address: wallet.address, rpcURL: config.solanaRPC)
            return formatSolBalance(lamports: lamports)
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

    /// Fetch all token balances for a wallet.
    func tokenBalances(for wallet: Wallet, config: NetworkConfig) async -> [TokenBalance] {
        let tokens = TokenList.tokens(for: wallet.chain)
        guard !tokens.isEmpty else { return [] }

        switch wallet.chain {
        case .ethereum:
            return await erc20Balances(tokens: tokens, ownerAddress: wallet.address, rpcURL: config.ethereumRPC)
        case .solana:
            return await splTokenBalances(tokens: tokens, ownerAddress: wallet.address, rpcURL: config.solanaRPC)
        case .bitcoin:
            return []
        }
    }

    // MARK: - Private Helpers

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

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)

        struct RPCResponse<T: Decodable>: Decodable {
            let result: T?
            let error: RPCError?
        }
        struct RPCError: Decodable {
            let code: Int
            let message: String
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

    private func formatEthBalance(wei: String) -> String {
        guard let value = Double(wei) else { return "0 ETH" }
        let eth = value / 1e18
        if eth == 0 { return "0 ETH" }
        if eth < 0.0001 { return String(format: "%.8f ETH", eth) }
        return String(format: "%.4f ETH", eth)
    }

    private func formatBtcBalance(satoshis: UInt64) -> String {
        let btc = Double(satoshis) / 1e8
        if btc == 0 { return "0 BTC" }
        if btc < 0.0001 { return String(format: "%.8f BTC", btc) }
        return String(format: "%.8f BTC", btc)
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
}
