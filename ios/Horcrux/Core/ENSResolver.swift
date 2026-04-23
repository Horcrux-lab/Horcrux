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
    /// Default RPC used for ENS lookups. ENS is deployed on Ethereum
    /// mainnet only, so we always query the mainnet Alchemy paid template
    /// (routed through `NetworkConfig.substituteAPIKey`). When no Alchemy
    /// key is set, the substitution layer falls back to the free public
    /// endpoint automatically.
    private static var rpcURL: String {
        let cfg = NetworkConfig.shared
        let template = RPCProviderTemplate.alchemy(evm: .mainnet)
            ?? EVMNetwork.mainnet.publicDefaultRPC
        return cfg.substituteAPIKey(in: template, chain: .ethereum)
    }

    /// Tiny memoisation so the signing form's "recipient → .eth" badge
    /// doesn't re-hit the RPC on every keystroke once we've resolved.
    private static var reverseCache: [String: String?] = [:]

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

    /// Reverse-resolve an Ethereum address to its primary ENS name
    /// (e.g. "0xd8dA…96045" → "vitalik.eth"). Returns nil when no
    /// primary name is set, resolution fails, or the forward-verify
    /// check (resolve(name) == address) doesn't match — which is
    /// what ENS best-practice calls for to prevent spoofing.
    static func reverse(_ address: String) async -> String? {
        let normalized = address.lowercased()
        guard normalized.hasPrefix("0x"), normalized.count == 42 else { return nil }
        if let cached = reverseCache[normalized] { return cached }

        let addrHex = String(normalized.dropFirst(2))
        let reverseName = "\(addrHex).addr.reverse"
        let nameHash = namehash(reverseName)

        // 1. registry.resolver(nameHash)
        let resolverCallData = "0x0178b8bf" + nameHash
        guard let resolver = await ethCall(to: registry, data: resolverCallData),
              resolver.count >= 42 else {
            reverseCache[normalized] = .some(nil)
            return nil
        }
        let resolverAddr = "0x" + String(resolver.suffix(40))
        guard resolverAddr != "0x0000000000000000000000000000000000000000" else {
            reverseCache[normalized] = .some(nil)
            return nil
        }

        // 2. resolver.name(nameHash) → string (ABI-encoded: offset, length, utf8 bytes)
        let nameCallData = "0x691f3431" + nameHash // selector for name(bytes32)
        guard let raw = await ethCall(to: resolverAddr, data: nameCallData),
              let name = decodeAbiString(raw), !name.isEmpty else {
            reverseCache[normalized] = .some(nil)
            return nil
        }

        // 3. Forward-verify: the claimed .eth must resolve back to this address.
        guard let forward = await resolve(name),
              forward.lowercased() == normalized else {
            reverseCache[normalized] = .some(nil)
            return nil
        }

        reverseCache[normalized] = .some(name)
        return name
    }

    /// Decode a solidity-ABI-encoded dynamic `string` return value.
    /// Layout: 32-byte offset (usually 0x20) | 32-byte length | utf8 bytes zero-padded to 32.
    private static func decodeAbiString(_ hex: String) -> String? {
        var s = hex
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count >= 128 else { return nil }
        // offset = first 32 bytes → usually 0x20 (32 decimal)
        let lengthHex = String(s.dropFirst(64).prefix(64))
        guard let length = UInt64(lengthHex, radix: 16), length > 0 else { return nil }
        let dataStart = 128
        let need = Int(length) * 2
        guard s.count >= dataStart + need else { return nil }
        let payload = String(s.dropFirst(dataStart).prefix(need))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(length))
        var idx = payload.startIndex
        while idx < payload.endIndex {
            let next = payload.index(idx, offsetBy: 2)
            if let b = UInt8(payload[idx..<next], radix: 16) {
                bytes.append(b)
            } else { return nil }
            idx = next
        }
        return String(data: Data(bytes), encoding: .utf8)
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
