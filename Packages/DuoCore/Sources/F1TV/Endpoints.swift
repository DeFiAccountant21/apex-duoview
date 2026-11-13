import Foundation

public enum Platform: String, Sendable, CaseIterable {
    case webHLS = "WEB_HLS"
    case webDASH = "WEB_DASH"
}

public enum Endpoints {
    public static let base = URL(string: "https://f1tv.formula1.com")!

    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15"

    /// `{BASE}/{version}/{A|R}/ENG/{platform}/ALL/{path}` plus an optional query.
    /// Query values are percent-encoded exactly once; commas stay literal.
    public static func url(
        version: String,
        signedIn: Bool,
        platform: Platform,
        path: String,
        query: [(String, String)] = []
    ) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/\(version)/\(signedIn ? "R" : "A")/ENG/\(platform.rawValue)/ALL/\(path)"
        if !query.isEmpty {
            components.percentEncodedQueryItems = query.map {
                URLQueryItem(name: encode($0.0), value: encode($0.1))
            }
        }
        return components.url!
    }

    public static func image(path: String, width: Int, height: Int) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/image-resizer/image/\(path)"
        components.percentEncodedQuery = "w=\(width)&h=\(height)&q=HI&o=L"
        return components.url!
    }

    public static func deviceInfo(multiview: Bool) -> String {
        "device=web;screen=browser;os=mac os;browser=safari;browserVersion=26.1;osVersion=10.15.7;appVersion=54.2.1;playerVersion=8.212.0;p=\(multiview);tms=1"
    }

    /// What the original Android app sends. F1 TV gives the whole multiview (`tme.channel` "MULTI")
    /// to this header, but only one feed ("SWITCHER") to the Safari one.
    public static func androidDeviceInfo(multiview: Bool) -> String {
        "device=web;screen=browser;os=android;browser=chrome;browserVersion=140;osVersion=14;appVersion=54.2.1;playerVersion=8.212.0;p=\(multiview);tms=1"
    }

    public static let androidUserAgent =
        "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/AP2A.240805.005) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/140.0.7339.207 Mobile Safari/537.36"

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+")
        return set
    }()

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }
}
