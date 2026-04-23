import SwiftUI
import UIKit

/// A lightweight "已复制" toast, globally dispatched via `CopyFeedback.copy(_:)`.
///
/// Design rationale: the scene-level overlay keeps the feedback consistent
/// across every copy-to-clipboard affordance (signing preview, wallet detail,
/// DKG complete, address book, etc.) without requiring each view to host its
/// own @State. Uses a singleton `ObservableObject` so ContentView can inject
/// one overlay once and every copy call just toggles it.
@MainActor
final class CopyFeedback: ObservableObject {
    static let shared = CopyFeedback()

    @Published fileprivate(set) var message: String?
    private var hideTask: Task<Void, Never>?

    private init() {}

    /// Copy `value` to the clipboard and flash a transient toast.
    /// Pass an optional `label` to override the toast text (e.g. "地址已复制").
    ///
    /// Routed through `SecureClipboard.copy` so every app-wide copy gets the
    /// `UIPasteboard.expirationDate` auto-clear (60 s default). Call
    /// `SecureClipboard.copy` directly if you need a non-default expiration.
    static func copy(_ value: String, label: String = L10n.Common.copied) {
        SecureClipboard.copy(value, toast: label)
    }

    /// Emits the toast without touching the clipboard. Used by `SecureClipboard`
    /// so the secure-copy path (which has its own pasteboard call) still gets UI feedback.
    static func showToast(_ text: String) {
        shared.show(text)
    }

    private func show(_ text: String) {
        message = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if !Task.isCancelled {
                self?.message = nil
            }
        }
    }
}

/// View modifier that mounts the toast overlay at the top of the view hierarchy.
/// Apply once on the root scene (see `HorcruxApp`/`ContentView`).
struct CopyToastOverlay: ViewModifier {
    @ObservedObject private var feedback = CopyFeedback.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let msg = feedback.message {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(HorcruxTheme.accentPurple.opacity(0.25))
                            .frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(HorcruxTheme.accentCyan)
                    }
                    Text(msg)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [
                                        HorcruxTheme.accentPurple.opacity(0.18),
                                        HorcruxTheme.accentBlue.opacity(0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        )
                        .overlay(
                            Capsule().stroke(
                                LinearGradient(
                                    colors: [
                                        HorcruxTheme.accentPurple.opacity(0.55),
                                        HorcruxTheme.accentCyan.opacity(0.35)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                        )
                        .shadow(color: HorcruxTheme.accentPurple.opacity(0.35), radius: 16, y: 6)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                )
                .padding(.top, 14)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.9, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))
                    )
                )
                .zIndex(1000)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: feedback.message)
    }
}

extension View {
    /// Attach the global copy-to-clipboard toast. Apply once at the top of the view tree.
    func copyToastOverlay() -> some View { modifier(CopyToastOverlay()) }
}
