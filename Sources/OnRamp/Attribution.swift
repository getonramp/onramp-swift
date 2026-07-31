import Foundation

/// Ad platforms auto-tag landing/deep-link URLs with a click ID instead of
/// utm_* params (e.g. Google Ads appends only ?gclid=... unless a manual
/// tracking template is set up). Map known click IDs to utm equivalents so
/// paid traffic is still attributable. fbclid maps to "social" rather than
/// "cpc" because Facebook appends it to organic shares as well as ads.
///
/// Keep in sync with packages/sdk-core/src/attribution.ts.
enum ClickIdSource {
    static let table: [(param: String, source: String, medium: String)] = [
        ("gclid", "google", "cpc"),
        ("gbraid", "google", "cpc"),
        ("wbraid", "google", "cpc"),
        ("msclkid", "bing", "cpc"),
        ("ttclid", "tiktok", "cpc"),
        ("twclid", "twitter", "cpc"),
        ("li_fat_id", "linkedin", "cpc"),
        ("fbclid", "facebook", "social"),
    ]
}

enum AttributionParser {
    private static let utmKeys = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"]

    /// Parses utm_* params (falling back to a known ad click ID) from a URL -
    /// e.g. the Universal Link/custom-scheme URL that opened or resumed the app.
    static func utm(from url: URL) -> [String: String]? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        return utm(fromQueryItems: components.queryItems ?? [])
    }

    private static func utm(fromQueryItems queryItems: [URLQueryItem]) -> [String: String]? {
        var result: [String: String] = [:]
        for item in queryItems {
            guard let value = item.value, !value.isEmpty, utmKeys.contains(item.name) else { continue }
            result["_\(item.name)"] = value
        }
        if !result.isEmpty { return result }

        for (param, source, medium) in ClickIdSource.table {
            if let match = queryItems.first(where: { $0.name == param }), let value = match.value, !value.isEmpty {
                return ["_utm_source": source, "_utm_medium": medium]
            }
        }
        return nil
    }
}
