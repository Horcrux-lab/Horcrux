import SwiftUI

/// Circular progress ring used during DKG and signing ceremonies.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 12
    var color: Color = HorcruxTheme.accentColor

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)

            Text("\(Int(progress * 100))%")
                .font(.title2.bold().monospacedDigit())
        }
    }
}

/// Badge showing t-of-n threshold.
struct ShardStatusBadge: View {
    let threshold: UInt16
    let total: UInt16

    var body: some View {
        Text("\(threshold)/\(total)")
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(HorcruxTheme.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(HorcruxTheme.accentColor)
    }
}

/// Chain logo icon.
struct ChainIcon: View {
    let chain: Chain
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: chain.iconName)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(chain.color.opacity(0.15), in: Circle())
            .foregroundStyle(chain.color)
    }
}
