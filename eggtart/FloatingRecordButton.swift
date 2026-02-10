import SwiftUI

struct FloatingRecordButton: View {
    @Binding var position: CGPoint
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let buttonSize: CGFloat = 58
            let radius = buttonSize / 2

            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red : Color.white)
                        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)

                    Circle()
                        .stroke(isRecording ? Color.white.opacity(0.7) : Color.red, lineWidth: 2)
                        .frame(width: 22, height: 22)
                }
                .frame(width: buttonSize, height: buttonSize)
            }
            .buttonStyle(.plain)
            .position(currentPosition(in: size, radius: radius))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        position = clamp(value.location, in: size, radius: radius)
                    }
                    .onEnded { value in
                        var snapped = clamp(value.location, in: size, radius: radius)
                        snapped.x = snapped.x < size.width / 2 ? radius + 8 : size.width - radius - 8
                        position = snapped
                    }
            )
            .onAppear {
                if position == .zero {
                    position = CGPoint(x: size.width - radius - 8, y: size.height * 0.55)
                }
            }
        }
    }

    private func clamp(_ point: CGPoint, in size: CGSize, radius: CGFloat) -> CGPoint {
        let x = min(max(point.x, radius + 8), size.width - radius - 8)
        let y = min(max(point.y, radius + 8), size.height - radius - 8)
        return CGPoint(x: x, y: y)
    }

    private func currentPosition(in size: CGSize, radius: CGFloat) -> CGPoint {
        if position == .zero {
            return CGPoint(x: size.width - radius - 8, y: size.height * 0.55)
        }
        return clamp(position, in: size, radius: radius)
    }
}
