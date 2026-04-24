import SwiftUI

/// Small inline "ⓘ" button that reveals long-form help text in a popover on
/// tap. Replaces always-visible multi-line captions that push the primary
/// content below the fold. The title is optional; when present it becomes
/// the popover's bold header row.
///
/// Usage:
/// ```swift
/// HStack {
///     Text(L10n.Settings.rotateTitle).font(.headline)
///     InfoHint(title: L10n.Settings.rotateTitle,
///              body: L10n.Settings.rotateExplanationBody)
/// }
/// ```
///
/// The popover auto-sizes its width to the readable text width, caps at
/// 320pt on compact devices, and supports multi-paragraph bodies (use `\n`).
struct InfoHint: View {
    let title: String?
    let message: String

    @State private var isPresented = false

    init(title: String? = nil, body: String) {
        self.title = title
        self.message = body
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(HorcruxTheme.subtleText)
                .accessibilityLabel(title ?? L10n.Common.moreInfo)
                .accessibilityHint(L10n.Common.tapForDetails)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                }
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: 320, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }
}

#if DEBUG
struct InfoHint_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Rotate Shards").font(.headline)
                InfoHint(
                    title: "Why rotate?",
                    body: "MPC shards are strongest right after re-randomisation. Rotation refreshes entropy on every device without changing your wallet address."
                )
            }
            HStack {
                Text("Body-only").font(.headline)
                InfoHint(body: "Minimal usage — no header, just body text in the popover.")
            }
        }
        .padding()
    }
}
#endif
