import SwiftUI

/// Design tokens for the Horcrux app.
enum HorcruxTheme {
    static let accentColor = Color("AccentColor", bundle: nil)

    // Fallback accent if asset catalog not configured
    static let primaryColor = Color(red: 0.35, green: 0.55, blue: 1.0)

    static let backgroundGradient = LinearGradient(
        colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
        startPoint: .top,
        endPoint: .bottom
    )
}
