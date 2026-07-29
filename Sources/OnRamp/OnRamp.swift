import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class OnRamp {
    private init() {}

    private static let anonKey = "onramp_anonymous_id"
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

    // Overridden in tests to intercept HTTP calls without touching URLSession.shared.
    static var _urlSession: URLSession = .shared

    public static func initialize(
        apiKey: String,
        host: String = "https://ingest.getonramp.dev",
        appVersion: String? = nil
    ) {
        stateQueue.sync {
            self.apiKey = apiKey
            self.host = host.hasSuffix("/") ? String(host.dropLast()) : host
            self.appVersion = appVersion
            let defaults = UserDefaults.standard
            if let stored = defaults.string(forKey: anonKey) {
                anonymousId = stored
            } else {
                anonymousId = UUID().uuidString
                defaults.set(anonymousId, forKey: anonKey)
            }
            refreshSessionLocked()
        }
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
            if let p = properties { event["properties"] = p }
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
