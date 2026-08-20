import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AdServices)
import AdServices
#endif

public final class OnRamp {
    private init() {}

    private static let anonKey = "onramp_anonymous_id"
    private static let attributionKey = "onramp_pending_attribution"
    private static let searchAdsTokenSentKey = "onramp_search_ads_token_sent"
    private static let sessionTimeoutMs: Int64 = 30 * 60 * 1000

    // All mutable state below must only be touched while holding `stateQueue`
    // (via the `stateQueue.sync` block at each public entry point below).
    // step()/identify()/initialize()/newSession() can be called concurrently
    // from different threads, and without this these plain static vars would
    // race - producing duplicate/skipped step_index or torn session state.
    private static let stateQueue = DispatchQueue(label: "dev.getonramp.sdk.state")

    private static var apiKey = ""
    private static var host = ""
    private static var appVersion: String? = nil
    private static var anonymousId = ""
    private static var sessionId = UUID().uuidString
    private static var lastActive: Int64 = 0
    private static var stepIndex = 0

    // Install-scoped, not session-scoped: a deep link, MMP-provided
    // attribution, or Apple Search Ads result should attribute the install
    // exactly once, on the first tracked event ever, not be re-derived on
    // every app open.
    private static var captureInstallReferrer = true
    private static var pendingAttributionUtm: [String: String]? = nil
    private static var pendingAttributionChannel: String? = nil
    private static var attributionConsumed = false

    private struct StoredAttribution: Codable {
        var utm: [String: String]?
        var channel: String?
        var consumed: Bool
    }

    private static func loadAttributionLocked() -> StoredAttribution? {
        guard let data = UserDefaults.standard.data(forKey: attributionKey) else { return nil }
        return try? JSONDecoder().decode(StoredAttribution.self, from: data)
    }

    private static func saveAttributionLocked(_ attribution: StoredAttribution) {
        guard let data = try? JSONEncoder().encode(attribution) else { return }
        UserDefaults.standard.set(data, forKey: attributionKey)
    }

    // Overridden in tests to intercept HTTP calls without touching URLSession.shared.
    static var _urlSession: URLSession = .shared

    public static func initialize(
        apiKey: String,
        host: String = "https://ingest.getonramp.dev",
        appVersion: String? = nil,
        /// Capture install attribution (deep links via `handleDeepLink()`,
        /// and Apple Search Ads via the AdServices framework) automatically.
        /// Default **false** - opt-in, not opt-out, since turning this on
        /// starts collecting a new category of data and can touch the same
        /// OS-level APIs an existing MMP (Adjust, AppsFlyer, Branch) already
        /// reads. Set to `true` to enable OnRamp's own capture; otherwise
        /// call `OnRamp.setAttribution()` from your MMP's resolved-attribution
        /// callback instead - matches the same flag on the other OnRamp SDKs.
        captureInstallReferrer: Bool = false
    ) {
        var shouldCaptureSearchAds = false
        var anonIdForToken = ""
        var hostForToken = ""
        var keyForToken = ""

        stateQueue.sync {
            self.apiKey = apiKey
            self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
            self.appVersion = appVersion
            self.captureInstallReferrer = captureInstallReferrer
            let defaults = UserDefaults.standard
            if let stored = defaults.string(forKey: anonKey) {
                anonymousId = stored
            } else {
                anonymousId = UUID().uuidString
                defaults.set(anonymousId, forKey: anonKey)
            }
            refreshSessionLocked()

            let stored = loadAttributionLocked()
            attributionConsumed = stored?.consumed ?? false
            if captureInstallReferrer && !attributionConsumed {
                pendingAttributionUtm = stored?.utm
                pendingAttributionChannel = stored?.channel
                if !defaults.bool(forKey: searchAdsTokenSentKey) {
                    shouldCaptureSearchAds = true
                    anonIdForToken = anonymousId
                    hostForToken = self.host
                    keyForToken = self.apiKey
                }
            }
        }

        if shouldCaptureSearchAds {
            // Local token generation only (no network) but dispatched off the
            // calling thread anyway, since initialize() is typically called
            // from app startup on the main thread.
            DispatchQueue.global(qos: .utility).async {
                captureSearchAdsAttributionIfAvailable(anonymousId: anonIdForToken, host: hostForToken, apiKey: keyForToken)
            }
        }
    }

    /// Forward the URL your app receives via a Universal Link, custom scheme
    /// launch, or `continueUserActivity` - e.g. from
    /// `application(_:continue:restorationHandler:)`, `.onOpenURL`, or
    /// `.onContinueUserActivity` in SwiftUI. Captures `utm_*` params (falling
    /// back to known ad click IDs) and attaches them to this install's first
    /// tracked event, once.
    public static func handleDeepLink(_ url: URL) {
        stateQueue.sync {
            guard captureInstallReferrer, !attributionConsumed else { return }
            guard let utm = AttributionParser.utm(from: url) else { return }
            pendingAttributionUtm = utm
            pendingAttributionChannel = "deep_link"
            saveAttributionLocked(StoredAttribution(utm: utm, channel: "deep_link", consumed: false))
        }
    }

    /// Manually record install attribution resolved by your own MMP (Adjust,
    /// AppsFlyer, Branch, etc). Call this from that SDK's attribution-resolved
    /// callback if you've set `captureInstallReferrer: false` in
    /// `OnRamp.initialize()` instead of relying on OnRamp's own capture.
    /// No-ops if attribution has already been attached to this install's
    /// first tracked event.
    public static func setAttribution(
        provider: String? = nil,
        source: String,
        medium: String? = nil,
        campaign: String? = nil,
        term: String? = nil,
        content: String? = nil
    ) {
        stateQueue.sync {
            guard !attributionConsumed else { return }
            var utm: [String: String] = ["_utm_source": source]
            if let provider = provider { utm["_attribution_provider"] = provider }
            if let medium = medium { utm["_utm_medium"] = medium }
            if let campaign = campaign { utm["_utm_campaign"] = campaign }
            if let term = term { utm["_utm_term"] = term }
            if let content = content { utm["_utm_content"] = content }
            pendingAttributionUtm = utm
            pendingAttributionChannel = "mmp"
            saveAttributionLocked(StoredAttribution(utm: utm, channel: "mmp", consumed: false))
        }
    }

    /// Apple Search Ads attribution token capture (iOS 14.3+). The token
    /// itself is opaque and can't be resolved into a campaign/keyword
    /// on-device - it's exchanged server-side against Apple's endpoint, so
    /// this only sends it once per install and moves on. Does not require
    /// IDFA or an App Tracking Transparency prompt.
    private static func captureSearchAdsAttributionIfAvailable(anonymousId: String, host: String, apiKey: String) {
        guard !apiKey.isEmpty else { return }
        #if canImport(AdServices)
        guard #available(iOS 14.3, macOS 11.1, *) else { return }
        // Developer mode can return a synthetic `attribution: true` response.
        // TestFlight has a sandbox receipt as well, so only production App
        // Store installs may submit an Apple Ads token.
        #if targetEnvironment(simulator)
        return
        #else
        guard let receiptURL = Bundle.main.appStoreReceiptURL,
              receiptURL.lastPathComponent != "sandboxReceipt" else { return }
        #endif
        guard let token = try? AAAttribution.attributionToken() else { return }
        UserDefaults.standard.set(true, forKey: searchAdsTokenSentKey)

        guard let url = URL(string: "\(host)/v1/attribution/apple-search-ads"),
              let body = try? JSONSerialization.data(withJSONObject: [
                "token": token,
                "anonymous_id": anonymousId,
              ])
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-onramp-key")
        req.httpBody = body
        _urlSession.dataTask(with: req).resume()
        #endif
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Must only be called while holding `stateQueue`.
    private static func refreshSessionLocked() {
        let n = nowMs()
        if n - lastActive > sessionTimeoutMs {
            sessionId = UUID().uuidString
            stepIndex = 0
        }
        lastActive = n
    }

    public static func step(_ name: String, properties: [String: Any]? = nil) {
        let (event, apiKey, host): ([String: Any], String, String) = stateQueue.sync {
            refreshSessionLocked()
            let idx = stepIndex; stepIndex += 1

            var mergedProperties: [String: Any] = properties ?? [:]
            if !attributionConsumed {
                if let utm = pendingAttributionUtm {
                    for (key, value) in utm { mergedProperties[key] = value }
                }
                if let channel = pendingAttributionChannel {
                    mergedProperties["_attribution_channel"] = channel
                }
                attributionConsumed = true
                pendingAttributionUtm = nil
                pendingAttributionChannel = nil
                saveAttributionLocked(StoredAttribution(utm: nil, channel: nil, consumed: true))
            }

            var event: [String: Any] = [
                "schema_version": "1.0",
                "event_id": UUID().uuidString,
                "event_type": "step_entered",
                "app_key": self.apiKey,
                "session_id": sessionId,
                "anonymous_id": anonymousId,
                "step_name": name,
                "step_index": idx,
                "client_timestamp_ms": nowMs(),
                "platform": "ios",
                "os_version": osVersion,
                "device_model": deviceModel,
                "device_type": deviceType,
            ]
            if let v = appVersion { event["app_version"] = v }
            if !mergedProperties.isEmpty { event["properties"] = mergedProperties }
            return (event, self.apiKey, self.host)
        }
        send(event, apiKey: apiKey, host: host)
    }

    public static func identify(_ traits: [String: Any]) {
        let (event, apiKey, host): ([String: Any], String, String) = stateQueue.sync {
            refreshSessionLocked()
            var event: [String: Any] = [
                "schema_version": "1.0",
                "event_id": UUID().uuidString,
                "event_type": "identify",
                "app_key": self.apiKey,
                "session_id": sessionId,
                "anonymous_id": anonymousId,
                "step_name": "_identify",
                "step_index": 0,
                "client_timestamp_ms": nowMs(),
                "platform": "ios",
                "properties": traits,
            ]
            if let v = appVersion { event["app_version"] = v }
            return (event, self.apiKey, self.host)
        }
        send(event, apiKey: apiKey, host: host)
    }

    /// The current anonymous and session IDs - e.g. to pass the anonymous ID
    /// into a third-party SDK (like RevenueCat's `appUserID`) so purchase
    /// events can be matched back to this OnRamp identity. Call after
    /// `initialize()`.
    public static func getIds() -> (anonymousId: String, sessionId: String) {
        stateQueue.sync { (anonymousId, sessionId) }
    }

    /// Call after sign-out so the next user gets a fresh session.
    public static func newSession() {
        stateQueue.sync {
            sessionId = UUID().uuidString
            stepIndex = 0
            lastActive = 0
        }
    }

    private static func send(_ event: [String: Any], apiKey: String, host: String) {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(host)/v1/events"),
              let body = try? JSONSerialization.data(withJSONObject: ["events": [event]])
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-onramp-key")
        req.httpBody = body
        _urlSession.dataTask(with: req).resume()
    }

    #if canImport(UIKit)
    private static var osVersion: String { UIDevice.current.systemVersion }
    private static var deviceModel: String { UIDevice.current.model }
    private static var deviceType: String { UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone" }
    #else
    private static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
    private static var deviceModel: String { "mac" }
    private static var deviceType: String { "desktop" }
    #endif
}
