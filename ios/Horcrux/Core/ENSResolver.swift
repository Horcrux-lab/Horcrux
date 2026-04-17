import Foundation

/// Minimal ENS name resolver. Uses a public Ethereum RPC and the ENS
/// public resolver contract to turn `name.eth` into an Ethereum address.
///
/// This is intentionally simple: we delegate to the `eth_call` wrapper
/// already exposed by the app's RPC layer and compute the name-hash
/// (namehash) in pure Swift.
enum ENSResolver {
    /// ENS Registry contract on mainnet.
    private static let registry = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"
    /// Default RPC used for ENS lookups. Could be swapped for NetworkConfig.ethereumRPC.
    private static let rpcURL = "https://ethereum-rpc.publicnode.com"

    /// Resolve an ENS name (e.g. "vitalik.eth") to a hex address.
    /// Returns `nil` if resolution fails or the name isn't registered.
    static func resolve(_ name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasSuffix(".eth") else { return nil }

        let nameHash = namehash(trimmed)
        // 1. Call registry.resolver(nameHash) → resolver address
        let resolverCallData = "0x0178b8bf" + nameHash  // selector for resolver(bytes32)
        guard let resolver = await ethCall(to: registry, data: resolverCallData),
              resolver.count >= 42 else {
            return nil
        }
        let resolverAddr = "0x" + String(resolver.suffix(40))
        guard resolverAddr != "0x0000000000000000000000000000000000000000" else { return nil }

        // 2. Call resolver.addr(nameHash) → address
        let addrCallData = "0x3b3b57de" + nameHash  // selector for addr(bytes32)
        guard let addrRaw = await ethCall(to: resolverAddr, data: addrCallData),
              addrRaw.count >= 42 else {
            return nil
        }
        let addr = "0x" + String(addrRaw.suffix(40))
        return addr == "0x0000000000000000000000000000000000000000" ? nil : addr
    }

    /// Namehash implementation (EIP-137). Returns hex string without 0x prefix, 64 chars.
    private static func namehash(_ name: String) -> String {
        var node = Data(count: 32) // all zeros
        if !name.isEmpty {
            let labels = name.split(separator: ".").reversed()
            for label in labels {
                let labelHash = horcruxKeccak256(data: Data(label.utf8))
                node = horcruxKeccak256(data: node + labelHash)
            }
        }
        return node.map { String(format: "%02x", $0) }.joined()
    }

    /// Perform an eth_call and return the "result" hex string (with 0x prefix), or nil.
    private static func ethCall(to: String, data: String) async -> String? {
        guard let url = URL(string: rpcURL) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [["to": to, "data": data], "latest"]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: cfg)
        do {
            let (payload, _) = try await session.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let result = json["result"] as? String {
                return result
            }
        } catch {
            return nil
        }
        return nil
    }
}
