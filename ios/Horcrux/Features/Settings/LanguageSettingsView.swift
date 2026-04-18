import SwiftUI

/// In-app language switcher.
///
/// iOS honours the `AppleLanguages` UserDefaults key for per-app
/// language preference; writing `["en"]` here is equivalent to what
/// System Settings → Horcrux → Preferred Language does. The change
/// takes effect on next launch, so we surface an explicit restart
/// prompt rather than trying to hot-swap localisations at runtime.
struct LanguageSettingsView: View {
    enum Option: String, CaseIterable, Identifiable {
        case system
        case zhHans = "zh-Hans"
        case en = "en"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "跟随系统 / System"
            case .zhHans: return "简体中文"
            case .en: return "English"
            }
        }

        /// The value written to `AppleLanguages`. `nil` means "remove the
        /// override" and fall back to the system language.
        var appleLanguagesValue: [String]? {
            switch self {
            case .system: return nil
            case .zhHans: return ["zh-Hans"]
            case .en: return ["en"]
            }
        }
    }

    @State private var selection: Option = Self.currentSelection()
    @State private var showRestartAlert = false

    var body: some View {
        Form {
            Section {
                ForEach(Option.allCases) { opt in
                    Button {
                        apply(opt)
                    } label: {
                        HStack {
                            Text(opt.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection == opt {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityIdentifier("language_option_\(opt.rawValue)")
                }
            } footer: {
                Text("切换后请退出并重新打开 App（上滑关闭再打开即可），新语言下次启动生效。\nRestart the app for the new language to take effect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("语言 / Language")
        .navigationBarTitleDisplayMode(.inline)
        .alert("下次启动生效 / Applied on Next Launch", isPresented: $showRestartAlert) {
            Button("好 / OK", role: .cancel) {}
        } message: {
            Text("请手动退出并重新打开 App 以看到新语言。\nClose and reopen Horcrux to apply.")
        }
    }

    // MARK: - Apply

    private func apply(_ opt: Option) {
        selection = opt
        let defaults = UserDefaults.standard
        if let value = opt.appleLanguagesValue {
            defaults.set(value, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
        showRestartAlert = true
    }

    private static func currentSelection() -> Option {
        guard let arr = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              let first = arr.first else {
            return .system
        }
        if first.hasPrefix("zh") { return .zhHans }
        if first.hasPrefix("en") { return .en }
        return .system
    }
}
