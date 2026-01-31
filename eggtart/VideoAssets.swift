import Foundation

enum VideoAsset: String, CaseIterable {
    case `default` = "default"
    case sleep
    case sleeptowake
    case waketosleep

    case listening1
    case listening2
    case listening3

    case speaking1
    case speaking2
    case speaking3

    case happy
    case angry
    case sad
    case bored

    case headtap
    case midtap
    case bottomtap
    case friedegg
    case chicken
}

enum VideoResolver {
    static func url(for name: String) -> URL {
        let missingFallback: Set<String> = [
            "listening2", "listening3", "speaking2", "speaking3"
        ]
        let resolvedName = missingFallback.contains(name) ? "default" : name
        let bundle = Bundle.main
        if let url = bundle.url(forResource: resolvedName, withExtension: "mp4") {
            return url
        }
        if let fallback = bundle.url(forResource: "default", withExtension: "mp4") {
            return fallback
        }
        return URL(fileURLWithPath: "/dev/null")
    }
}

extension VideoAsset {
    var url: URL {
        VideoResolver.url(for: rawValue)
    }
}
