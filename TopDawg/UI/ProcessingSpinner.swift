import SwiftUI

/// Animated text spinner cycling through symbols — from claude-island's design language.
/// Cycles `["·", "✢", "✳", "∗", "✻", "✽"]` every 0.15s.
struct ProcessingSpinner: View {
    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]

    var size: CGFloat = 14
    var color: Color   = .claudeCoralLight

    @State private var index  = 0
    @State private var timer: Timer?

    var body: some View {
        Text(symbols[index])
            .font(.system(size: size, weight: .medium))
            .foregroundColor(color)
            .animation(.none, value: index)
            .onAppear  { startTimer() }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            DispatchQueue.main.async {
                index = (index + 1) % symbols.count
            }
        }
    }
}
