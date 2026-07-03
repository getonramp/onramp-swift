# OnRamp iOS SDK

OnRamp SDK for iOS (Swift) — onboarding funnel visibility for native iOS apps.

Track where users drop off during onboarding, see step-by-step conversion, and segment by OS version, device type, or any custom property — all without video recording.

**[getonramp.dev](https://getonramp.dev)**

---

## Installation

In Xcode, go to **File → Add Package Dependencies**, paste the URL below, and click **Add Package**. Select the **OnRamp** library when prompted.

```
https://github.com/getonramp/onramp-swift
```

---

## Quick Start

```swift
import OnRamp

// UIKit — AppDelegate.swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    OnRamp.initialize(
        apiKey: "onr_YOUR_API_KEY",
        host: "https://ingest.getonramp.dev",
        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    )
    return true
}

// SwiftUI — @main App struct
@main struct MyApp: App {
    init() {
        OnRamp.initialize(
            apiKey: "onr_YOUR_API_KEY",
            host: "https://ingest.getonramp.dev",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

```swift
// At each meaningful onboarding milestone
OnRamp.step("account_created")
OnRamp.step("profile_completed", properties: ["plan": "free"])
OnRamp.step("first_action_done")

// After sign-in — link the anonymous journey to a real user
OnRamp.identify(["userId": user.id, "email": user.email])

// After sign-out — start a fresh session for the next user
OnRamp.newSession()
```

---

## API

| Method | Description |
|---|---|
| `OnRamp.initialize(apiKey:host:appVersion:)` | Initialize once at app start. Restores the previous session if the user returned within 30 min. |
| `OnRamp.step(_ name:properties:)` | Track a conversion milestone. Properties become breakdown dimensions in the dashboard. |
| `OnRamp.identify(_ traits:)` | Associate the current user with known traits (userId, email, plan, etc.). Call once after sign-in. |
| `OnRamp.newSession()` | Force a new session. Call after sign-out so the next user starts fresh. |

---

## Funnels

Funnels are **defined in the dashboard**, not in the SDK. Call `OnRamp.step()` anywhere with a name — no routing, no step index, no ceremony. Then in the dashboard pick which steps belong to a funnel, in what order, and instantly see historical conversion.

This means you can reorder steps or add new ones in the dashboard without shipping an app update.
