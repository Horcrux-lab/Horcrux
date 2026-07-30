import SwiftUI

/// Short, consistent vocabulary for where a chain's traffic goes.
///
/// Lives here rather than in `EndpointSource.swift` so `L10n` stays
/// outside the RPC path. The `.provider` case uses `p.displayName` —
/// a brand name — consistent with how the picker labels it above.
extension EndpointSource {
    var label: String {
        switch self {
        case .override:         return L10n.NodeSettings.sourceLabelCustom
        case .provider(let p):  return p.displayName
        case .publicDefault:    return L10n.NodeSettings.sourceLabelPublic
        }
    }
}

struct ChainEndpointList: View {
    @ObservedObject private var config = NetworkConfig.shared
    /// Held for reactivity: `overrides.objectWillChange` triggers a re-render
    /// so the badge updates immediately after a set/clear. The body reads
    /// `config.endpointSource(for:)`, which internally calls `url(for:)` on
    /// the lock-guarded store — not this mirror — for a consistent
    /// classification. Do not remove this property even though the body
    /// doesn't reference it directly.
    @ObservedObject private var overrides = ChainEndpointOverrides.shared

    var body: some View {
        Section(L10n.NodeSettings.chainsSection) {
            ForEach(Chain.allCases) { chain in
                NavigationLink {
                    ChainEndpointDetailView(chain: chain)
                } label: {
                    HStack {
                        Text(chain.displayName)
                        Spacer()
                        Text(config.endpointSource(for: chain).label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("nodeSettings_chainRow_\(chain.rawValue)")
            }
        }
    }
}
