import SwiftUI

struct RippleButton<Content: View>: View {
    let isActive: Bool
    let action: () -> Void
    let content: () -> Content

    @State private var pulse: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isActive {
                    Circle()
                        .stroke(EggtartTheme.accent.opacity(0.35), lineWidth: 2)
                        .frame(width: pulse ? 88 : 52, height: pulse ? 88 : 52)
                        .opacity(pulse ? 0.0 : 1.0)
                        .animation(
                            .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                            value: pulse
                        )
                }
                content()
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
