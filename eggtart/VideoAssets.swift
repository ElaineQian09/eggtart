import Foundation

enum VideoAsset: String, CaseIterable {
    case `default` = "default"
    case sleep
    case sleeptowake
    case waketosleep

    case listening1
    case speaking1

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
        let resolvedName = name
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
