import SwiftUI

/// Renders a decoded EVM calldata `FfiDecodedCall` (produced by
/// `HorcruxBridge.decodeEvmCalldata(_:)`) so the cosigner sees a
/// human-readable interpretation of what they're being asked to sign
/// instead of an opaque hex blob.
///
/// Audit finding **C4** (see `docs/security-audit-2026-04.md`): before
/// this view the cosigner only saw the initiator's self-reported
/// recipient / amount / token symbol. A malicious initiator could lie
/// in those fields while the actual calldata signed a different
/// contract call. The decoder recomputes intent from the actual bytes,
/// and this view surfaces that intent alongside a warning band whose
/// severity scales with the call.
///
/// Severity → visual weight:
///   • `transfer` (empty data, native) / `erc20Transfer` → neutral info.
///   • `erc20TransferFrom` → amber warning (pull semantics).
///   • `erc20Approve(isUnlimited: false)` → amber warning.
///   • `erc20Approve(isUnlimited: true)` → red, hard-block —
///     `requiresExplicitConsent` becomes `true` and the caller is
///     expected to gate its primary action behind the returned toggle
///     binding.
///   • `setApprovalForAll(approved: true)` → red, hard-block.
///   • `unknown` → amber; caller should encourage the user to verify
///     the contract out-of-band.
struct DecodedCallView: View {
    let decoded: FfiDecodedCall

    /// Bound to the "I understand this is an unlimited approval" /
    /// "I understand this approves all of my NFTs" toggle. Only rendered
    /// when the decoded call is destructive enough to warrant an
    /// explicit consent gate (see `requiresExplicitConsent`).
    @Binding var explicitConsent: Bool

    /// Whether the caller must gate its primary action behind
    /// `explicitConsent`. The caller reads this flag to decide whether
    /// to disable its Approve button until the toggle is flipped.
    var requiresExplicitConsent: Bool {
        switch decoded {
        case .erc20Approve(_, _, let isUnlimited):
            return isUnlimited
        case .setApprovalForAll(_, let approved):
            return approved
        default:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(severityColor)
                Text(titleLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            ForEach(fields, id: \.label) { field in
                HStack(alignment: .top) {
                    Text(field.label)
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                    Spacer()
                    Text(field.value)
                        .font(.system(.footnote, design: field.mono ? .monospaced : .default))
                        .foregroundStyle(field.emphasis ? severityColor : .white)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let warning = warningText {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(severityColor)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if requiresExplicitConsent {
                Toggle(isOn: $explicitConsent) {
                    Text(consentLabel)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(severityColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(severityColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(severityColor.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Presentation

    private struct Field {
        let label: String
        let value: String
        var mono: Bool = false
        var emphasis: Bool = false
    }

    private var iconName: String {
        switch decoded {
        case .transfer, .erc20Transfer:
            return "arrow.up.right.circle"
        case .erc20TransferFrom:
            return "arrow.down.circle"
        case .erc20Approve(_, _, let isUnlimited):
            return isUnlimited ? "exclamationmark.triangle.fill" : "checkmark.shield"
        case .setApprovalForAll(_, let approved):
            return approved ? "exclamationmark.triangle.fill" : "checkmark.shield"
        case .unknown:
            return "questionmark.diamond"
        }
    }

    private var titleLabel: String {
        switch decoded {
        case .transfer:
            return L10n.DecodedCall.titleNativeTransfer
        case .erc20Transfer:
            return L10n.DecodedCall.titleErc20Transfer
        case .erc20TransferFrom:
            return L10n.DecodedCall.titleErc20TransferFrom
        case .erc20Approve(_, _, let isUnlimited):
            return isUnlimited
                ? L10n.DecodedCall.titleApproveUnlimited
                : L10n.DecodedCall.titleApprove
        case .setApprovalForAll(_, let approved):
            return approved
                ? L10n.DecodedCall.titleSetApprovalForAllTrue
                : L10n.DecodedCall.titleSetApprovalForAllFalse
        case .unknown:
            return L10n.DecodedCall.titleUnknown
        }
    }

    private var severityColor: Color {
        switch decoded {
        case .transfer, .erc20Transfer:
            return HorcruxTheme.accentCyan
        case .erc20TransferFrom, .unknown:
            return HorcruxTheme.warningAmber
        case .erc20Approve(_, _, let isUnlimited):
            return isUnlimited ? HorcruxTheme.dangerRed : HorcruxTheme.warningAmber
        case .setApprovalForAll(_, let approved):
            return approved ? HorcruxTheme.dangerRed : HorcruxTheme.accentCyan
        }
    }

    private var fields: [Field] {
        switch decoded {
        case .transfer:
            return [
                Field(label: L10n.DecodedCall.fieldKind, value: L10n.DecodedCall.titleNativeTransfer)
            ]
        case .erc20Transfer(let to, let amountHex):
            return [
                Field(label: L10n.DecodedCall.fieldTo,
                      value: AddressFormatter.chunked(to), mono: true),
                Field(label: L10n.DecodedCall.fieldAmountRaw,
                      value: "0x" + amountHex, mono: true)
            ]
        case .erc20TransferFrom(let from, let to, let amountHex):
            return [
                Field(label: L10n.DecodedCall.fieldFrom,
                      value: AddressFormatter.chunked(from), mono: true),
                Field(label: L10n.DecodedCall.fieldTo,
                      value: AddressFormatter.chunked(to), mono: true),
                Field(label: L10n.DecodedCall.fieldAmountRaw,
                      value: "0x" + amountHex, mono: true)
            ]
        case .erc20Approve(let spender, let amountHex, let isUnlimited):
            return [
                Field(label: L10n.DecodedCall.fieldSpender,
                      value: AddressFormatter.chunked(spender), mono: true),
                Field(label: L10n.DecodedCall.fieldAmountRaw,
                      value: isUnlimited ? L10n.DecodedCall.amountUnlimited : "0x" + amountHex,
                      mono: !isUnlimited,
                      emphasis: isUnlimited)
            ]
        case .setApprovalForAll(let op, let approved):
            return [
                Field(label: L10n.DecodedCall.fieldOperator,
                      value: AddressFormatter.chunked(op), mono: true),
                Field(label: L10n.DecodedCall.fieldApproved,
                      value: approved ? L10n.DecodedCall.approvedYes : L10n.DecodedCall.approvedNo,
                      emphasis: approved)
            ]
        case .unknown(let selectorHex, let dataLen):
            return [
                Field(label: L10n.DecodedCall.fieldSelector, value: "0x" + selectorHex, mono: true),
                Field(label: L10n.DecodedCall.fieldPayloadSize, value: "\(dataLen) B")
            ]
        }
    }

    private var warningText: String? {
        switch decoded {
        case .erc20Approve(_, _, let isUnlimited):
            return isUnlimited
                ? L10n.DecodedCall.warnApproveUnlimited
                : L10n.DecodedCall.warnApprove
        case .setApprovalForAll(_, let approved):
            return approved ? L10n.DecodedCall.warnSetApprovalForAll : nil
        case .erc20TransferFrom:
            return L10n.DecodedCall.warnTransferFrom
        case .unknown:
            return L10n.DecodedCall.warnUnknown
        default:
            return nil
        }
    }

    private var consentLabel: String {
        switch decoded {
        case .erc20Approve:
            return L10n.DecodedCall.consentUnlimitedApprove
        case .setApprovalForAll:
            return L10n.DecodedCall.consentSetApprovalForAll
        default:
            return ""
        }
    }
}
