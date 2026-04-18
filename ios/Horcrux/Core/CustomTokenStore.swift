import Foundation
import Combine

/// User-added tokens persisted to disk, merged into the built-in
/// `TokenList` at read time. Keyed by `Chain` so the same contract
/// address on different EVM chains stays distinct.
@MainActor
final class CustomTokenStore: ObservableObject {
    @Published private(set) var tokens: [Token] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let docs = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = fileURL ?? docs.appendingPathComponent("horcrux_custom_tokens.json")
        load()
    }

    /// Merge built-in and custom tokens for a chain. Custom entries with a
    /// contract matching a built-in are skipped to avoid duplicates.
    func effectiveTokens(for chain: Chain) -> [Token] {
        let builtin = TokenList.tokens(for: chain)
        let builtinIds = Set(builtin.map { $0.id.lowercased() })
        let custom = tokens.filter { $0.chain == chain && !builtinIds.contains($0.id.lowercased()) }
        return builtin + custom
    }

    func add(_ token: Token) {
        // Dedupe by (chain, id-lowercased).
        let key = token.id.lowercased()
        tokens.removeAll { $0.chain == token.chain && $0.id.lowercased() == key }
        tokens.append(token)
        save()
    }

    func remove(_ token: Token) {
        tokens.removeAll { $0.chain == token.chain && $0.id.lowercased() == token.id.lowercased() }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        tokens = (try? JSONDecoder().decode([Token].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
