import SwiftUI

/// Loosely mirrors UTM.app's own look: a translucent sidebar, rounded rows,
/// a system accent, and SF Symbols instead of custom art.
enum Theme {
    static let cornerRadius: CGFloat = 8
    static let rowSpacing: CGFloat = 2
    static let masterAccent = Color.accentColor
}

struct StatusDot: View {
    let status: VMStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .opacity(status.isTransitional ? (pulse ? 0.35 : 1.0) : 1.0)
            .onAppear {
                guard status.isTransitional else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}
