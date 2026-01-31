import SwiftUI

enum EggtartTheme {
    static let accent = Color(red: 0.93, green: 0.67, blue: 0.47)
    static let softMint = Color(red: 0.78, green: 0.90, blue: 0.86)
    static let softSky = Color(red: 0.78, green: 0.84, blue: 0.93)
    static let softPeach = Color(red: 0.98, green: 0.88, blue: 0.82)
    static let overlayDark = Color.black.opacity(0.22)

    static let topGradient = LinearGradient(
        colors: [Color.black.opacity(0.45), Color.black.opacity(0.0)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let bottomGradient = LinearGradient(
        colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
        startPoint: .top,
        endPoint: .bottom
    )
}
