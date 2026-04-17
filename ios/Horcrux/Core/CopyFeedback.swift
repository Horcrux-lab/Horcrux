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
    static func copy(_ value: String, label: String = "已复制") {
        UIPasteboard.general.string = value
        Haptics.selection()
        shared.show(label)
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
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(msg)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(Color.black.opacity(0.85))
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                )
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1000)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: feedback.message)
    }
}

extension View {
    /// Attach the global copy-to-clipboard toast. Apply once at the top of the view tree.
    func copyToastOverlay() -> some View { modifier(CopyToastOverlay()) }
}
