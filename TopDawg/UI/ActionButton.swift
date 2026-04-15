import SwiftUI

/// A reusable button that inverts on hover — inspired by claude-island's action buttons.
/// Default state: colored text + subtle tinted background.
/// Hover state: black text + full color background.
struct ActionButton: View {
    let title: String
    let icon: String?
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    init(_ title: String, icon: String? = nil, color: Color, action: @escaping () -> Void) {
        self.title  = title
        self.icon   = icon
        self.color  = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundColor(isHovered ? .black : color)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered ? color : color.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(color.opacity(isHovered ? 0 : 0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
