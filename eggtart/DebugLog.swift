import Foundation

private let debugLogFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func debugLog(_ message: String, file: String = #fileID, line: Int = #line) {
    let timestamp = debugLogFormatter.string(from: Date())
    print("[DEBUG] \(timestamp) \(message) (\(file):\(line))")
}
