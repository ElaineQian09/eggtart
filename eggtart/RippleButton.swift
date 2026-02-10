import SwiftUI

struct RippleButton<Content: View>: View {
    let isActive: Bool
    let action: () -> Void
    let content: () -> Content
    var size: CGFloat = 52

    @State private var pulse: Bool = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: size, height: size)
                .overlay {
                    if isActive {
                        Circle()
                            .stroke(EggtartTheme.accent.opacity(0.35), lineWidth: 2)
                            .scaleEffect(pulse ? 1.7 : 1.0)
                            .opacity(pulse ? 0.0 : 1.0)
                            .animation(
                                .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                value: pulse
                            )
                    }
                }
        }
        .onAppear {
            if isActive {
                pulse = true
            }
        }
        .onChange(of: isActive) { _, active in
            pulse = active
        }
    }
}
