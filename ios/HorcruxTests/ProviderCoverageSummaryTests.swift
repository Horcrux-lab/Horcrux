import XCTest
@testable import Horcrux

/// Table-driven tests for `ProviderCoverageSummary`.
///
/// Every test asserts on the *partition* — the three `Set<Chain>` properties —
/// not on exact localized prose. That keeps tests independent of string edits
/// while still catching the logic that matters: which chain lands in which bucket.
///
/// The mutation section at the bottom documents the expected red/green for the
/// override-ignoring mutation (removing `.subtracting(overriddenChains)` from
/// `providerCovered`). Run it manually when changing the init.
final class ProviderCoverageSummaryTests: XCTestCase {

    // MARK: - No key

    func test_noKey_noOverrides_allChainsOnPublicDefault() {
        let s = summary(.alchemy, hasKey: false, overrides: [])
        XCTAssertTrue(s.providerCovered.isEmpty)
        XCTAssertTrue(s.overridden.isEmpty)
        XCTAssertEqual(s.publicDefault, Set(Chain.allCases))
    }

    func test_noKey_withOverrides_overriddenChainsNotOnPublicDefault() {
        let s = summary(.alchemy, hasKey: false, overrides: [.bitcoin, .litecoin])
        XCTAssertTrue(s.providerCovered.isEmpty)
        XCTAssertEqual(s.overridden, [.bitcoin, .litecoin])
        XCTAssertFalse(s.publicDefault.contains(.bitcoin))
        XCTAssertFalse(s.publicDefault.contains(.litecoin))
        // Everything else is public default
        XCTAssertEqual(s.publicDefault.count, Chain.allCases.count - 2)
    }

    // MARK: - Key set, partial coverage

    func test_keyPartialCoverage_standardCase() {
        // Alchemy covers everything except BNB, Bitcoin, Litecoin, Tron on mainnet.
        let s = summary(.alchemy, hasKey: true, overrides: [])
        XCTAssertFalse(s.providerCovered.isEmpty)
        XCTAssertTrue(s.overridden.isEmpty)
        // Known uncovered chains must be in publicDefault
        XCTAssertTrue(s.publicDefault.contains(.bnb))
        XCTAssertTrue(s.publicDefault.contains(.bitcoin))
        XCTAssertTrue(s.publicDefault.contains(.litecoin))
        XCTAssertTrue(s.publicDefault.contains(.tron))
        // Alchemy covers Solana on mainnet
        XCTAssertTrue(s.providerCovered.contains(.solana))
        XCTAssertFalse(s.publicDefault.contains(.solana))
    }

    // MARK: - Override interactions

    /// Core correctness test for Finding 2: an override on a chain the provider
    /// serves must move that chain out of `providerCovered` and into `overridden`,
    /// not into `publicDefault`.
    func test_overrideShadowingProviderChain_chainMovesToOverridden() {
        // Alchemy covers .ethereum. Applying an override must shadow it.
        let s = summary(.alchemy, hasKey: true, overrides: [.ethereum])
        XCTAssertFalse(s.providerCovered.contains(.ethereum),
                       ".ethereum must not appear as provider-covered when it has an override")
        XCTAssertTrue(s.overridden.contains(.ethereum))
        XCTAssertFalse(s.publicDefault.contains(.ethereum),
                       ".ethereum must not appear as public-default when an override is serving it")
    }

    /// Bitcoin is served by no provider. An override must move it out of
    /// `publicDefault` and into `overridden` — not silently leave it as public.
    func test_overrideOnChainNoProviderServes_chainMovesToOverridden() {
        let s = summary(.alchemy, hasKey: true, overrides: [.bitcoin])
        XCTAssertTrue(s.overridden.contains(.bitcoin))
        XCTAssertFalse(s.publicDefault.contains(.bitcoin),
                       "Bitcoin with an override must not be reported as public-default")
        XCTAssertFalse(s.providerCovered.contains(.bitcoin))
    }

    /// Overrides on chains the provider cannot serve (Bitcoin, Litecoin, Tron)
    /// must all leave `publicDefault` clean.
    func test_overridesOnAllUnservedChains_publicDefaultExcludesThem() {
        let unserved: Set<Chain> = [.bitcoin, .litecoin, .tron]
        let s = summary(.alchemy, hasKey: true, overrides: unserved)
        for chain in unserved {
            XCTAssertFalse(s.publicDefault.contains(chain),
                           "\(chain) has an override and must not appear as public-default")
        }
    }

    // MARK: - Partition invariant

    /// The three groups must partition `Chain.allCases` for every provider,
    /// both with and without a key, and with a representative override set.
    func test_partitionIsExhaustiveAndDisjoint_acrossAllProviders() {
        let representativeOverrides: Set<Chain> = [.bitcoin, .ethereum]
        for provider in NodeProvider.allCases {
            for hasKey in [true, false] {
                let s = summary(provider, hasKey: hasKey, overrides: representativeOverrides)
                let union = s.overridden.union(s.providerCovered).union(s.publicDefault)
                XCTAssertEqual(union, Set(Chain.allCases),
                               "\(provider)/hasKey=\(hasKey): union must equal allCases")
                XCTAssertEqual(union.count, Chain.allCases.count,
                               "\(provider)/hasKey=\(hasKey): counts must match (no duplicates)")
                XCTAssertTrue(s.overridden.isDisjoint(with: s.providerCovered),
                              "\(provider): overridden ∩ providerCovered must be empty")
                XCTAssertTrue(s.overridden.isDisjoint(with: s.publicDefault),
                              "\(provider): overridden ∩ publicDefault must be empty")
                XCTAssertTrue(s.providerCovered.isDisjoint(with: s.publicDefault),
                              "\(provider): providerCovered ∩ publicDefault must be empty")
            }
        }
    }

    // MARK: - formattedCaption smoke tests (structure, not prose)

    func test_noKeyNoOverrides_captionContainsNoKeySignal() {
        let s = summary(.alchemy, hasKey: false, overrides: [])
        // The caption must not claim a provider is covering anything.
        XCTAssertFalse(s.formattedCaption.contains("Alchemy"))
    }

    func test_keyWithPartialCoverage_captionContainsBNBName() {
        // BNB is not served by Alchemy — must appear in the public-default list.
        let s = summary(.alchemy, hasKey: true, overrides: [])
        let bnbName = Chain.bnb.displayName
        XCTAssertTrue(s.formattedCaption.contains(bnbName),
                      "BNB is uncovered by Alchemy and must appear in the caption")
    }

    func test_overrideOnBitcoin_captionDoesNotContainBitcoinName() {
        // Bitcoin has an override — must NOT appear in the public-default sentence.
        let s = summary(.alchemy, hasKey: true, overrides: [.bitcoin])
        let btcName = Chain.bitcoin.displayName
        XCTAssertFalse(s.formattedCaption.contains(btcName),
                       "Bitcoin has an override and must not appear in the public-default sentence")
    }

    /// Partial coverage + at least one override: the caption must account for
    /// the overridden chains by including their count, so the numbers add up.
    ///
    /// Two overrides (Bitcoin, Litecoin) are used deliberately. With count=1,
    /// the string "1" is a substring of "14" (the total chain count), so the
    /// assertion could pass even if the override count were dropped. With
    /// count=2, "2" does not appear in "14" or in Alchemy's coverage numbers,
    /// making the substring check unambiguous.
    func test_partialCoverageWithOverrides_captionMentionsOverriddenCount() {
        // Alchemy leaves BNB and Tron on public defaults; Bitcoin and Litecoin
        // have overrides → publicDefault non-empty, overridden non-empty.
        let s = summary(.alchemy, hasKey: true, overrides: [.bitcoin, .litecoin])
        XCTAssertFalse(s.publicDefault.isEmpty, "precondition: Alchemy leaves some chains uncovered")
        XCTAssertEqual(s.overridden.count, 2, "precondition: exactly two overrides")
        XCTAssertTrue(s.formattedCaption.contains("2"),
                      "partial+override caption must include the overridden count (2) so the numbers add up to \(Chain.allCases.count)")
        XCTAssertFalse(s.formattedCaption.contains(Chain.bitcoin.displayName),
                       "Bitcoin's name must not appear in the public-default list")
        XCTAssertFalse(s.formattedCaption.contains(Chain.litecoin.displayName),
                       "Litecoin's name must not appear in the public-default list")
    }

    /// General property: whenever `overridden` is non-empty the caption must
    /// contain the override count as a number. This is assertable at the string
    /// level because every override-aware format key embeds the count directly.
    ///
    /// Scope note: the check uses `String(overridden.count)`, which could
    /// theoretically collide with other numbers in the caption (e.g. total
    /// chain count). That edge case does not occur with current providers and
    /// counts, but the assertion is worth less if `overridden.count` equals
    /// `Chain.allCases.count` (14) or a common sub-count. We use a distinctive
    /// override set of 3 chains to keep the signal clean.
    func test_whenOverriddenIsNonEmpty_captionAlwaysReflectsOverriddenCount() {
        let overrides: Set<Chain> = [.bitcoin, .litecoin, .tron]  // count = 3, distinct from totals
        for provider in NodeProvider.allCases {
            let s = summary(provider, hasKey: true, overrides: overrides)
            guard !s.overridden.isEmpty else { continue }
            XCTAssertTrue(s.formattedCaption.contains("3"),
                          "\(provider): caption must include the overridden count (3) when overridden is non-empty")
        }
    }

    // MARK: - nil provider

    /// When no provider is selected, any chain with an override must NOT be
    /// reported as a public endpoint — that is the lie the old else-branch
    /// told via providerPublicCaption.
    ///
    /// Uses three overrides (bitcoin, litecoin, tron) so the count "3" cannot
    /// collide as a substring with the 14-chain total or with publicDefault
    /// count "11". With a single-override count of "1", the assertion
    /// `contains("1")` would pass trivially because publicDefault.count is
    /// "13", which contains "1". Three is the minimum safe discriminator
    /// for the nil-provider case.
    func test_nilProvider_withOverrides_doesNotClaimEveryChainIsPublic() {
        let s = summary(nil, hasKey: false, overrides: [.bitcoin, .litecoin, .tron])
        XCTAssertEqual(s.overridden.count, 3)
        XCTAssertTrue(s.providerCovered.isEmpty, "nil provider must have no provider-covered chains")
        XCTAssertFalse(s.publicDefault.contains(.bitcoin),
                       "overridden chain must not be in publicDefault")
        XCTAssertFalse(s.publicDefault.contains(.litecoin),
                       "overridden chain must not be in publicDefault")
        XCTAssertFalse(s.publicDefault.contains(.tron),
                       "overridden chain must not be in publicDefault")
        // The caption must positively reflect the overridden count.
        // If %1$d is dropped from coverageNoKeyWithOverrides the "3" disappears
        // from the caption, making this assertion fail for the right reason.
        XCTAssertTrue(s.formattedCaption.contains("3"),
                      "nil provider + 3 overrides: caption must contain the override count '3'")
        XCTAssertNotEqual(s.formattedCaption, L10n.NodeSettings.coverageNoKey,
                          "nil provider + override must not claim every chain is on a public endpoint")
    }

    // MARK: - Helpers

    private func summary(_ provider: NodeProvider?,
                         hasKey: Bool,
                         overrides: Set<Chain>) -> ProviderCoverageSummary {
        ProviderCoverageSummary(provider: provider,
                                hasKey: hasKey,
                                overriddenChains: overrides,
                                evmChainId: 1,
                                solanaMainnet: true)
    }
}
