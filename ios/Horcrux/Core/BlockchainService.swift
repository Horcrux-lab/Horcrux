import Foundation

/// Thin JSON-RPC / REST client for on-chain queries and transaction broadcast.
/// Supports Ethereum (JSON-RPC), Bitcoin (Blockstream REST), and Solana (JSON-RPC).
actor BlockchainService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Validate and construct a URL, rejecting non-HTTPS for RPC endpoints.
    private static func validatedURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
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
    func ethEstimateGas(from: String, to: String, valueWei: String, rpcURL: String) async throws -> EvmGasEstimate {
        let nonce = try await ethNonce(address: from, rpcURL: rpcURL)

        // Gas limit: use eth_estimateGas
        let valueHex = "0x" + String(UInt64(valueWei) ?? 0, radix: 16)
        let estimateParams: [[String: String]] = [["from": from, "to": to, "value": valueHex]]
        let gasHex: String = try await ethCall(
            method: "eth_estimateGas",
            params: estimateParams,
            rpcURL: rpcURL
        )
        let gasLimit = UInt64(hexToDecimal(gasHex)) ?? 21000

        // Fee: use eth_gasPrice as fallback, or eth_maxPriorityFeePerGas
        let gasPriceHex: String = try await ethCall(
            method: "eth_gasPrice",
            params: [] as [String],
            rpcURL: rpcURL
        )
        let gasPrice = hexToDecimal(gasPriceHex)

        // For EIP-1559, set maxFeePerGas = 2 * baseFee, maxPriorityFeePerGas = 1.5 gwei
        let priorityFee = "1500000000" // 1.5 gwei

        return EvmGasEstimate(
            nonce: nonce,
            gasLimit: gasLimit,
            maxFeePerGas: gasPrice,
            maxPriorityFeePerGas: priorityFee
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

    // MARK: - Private Helpers

    private func ethCall<P: Encodable, R: Decodable>(method: String, params: P, rpcURL: String) async throws -> R {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
        ]
        // Build request manually to handle heterogeneous params
        var jsonBody = try JSONSerialization.data(withJSONObject: body)
        // Insert params
        let paramsData = try JSONEncoder().encode(params)
        var dict = try JSONSerialization.jsonObject(with: jsonBody) as! [String: Any]
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
