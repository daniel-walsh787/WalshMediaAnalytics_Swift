# WalshMediaAnalytics

Signed, batched analytics for Walsh Media iOS and Mac apps. The package queues events locally, HMAC-signs each flush, and `POST`s to `https://analytics.walshmedia.net.au/v1/ingest`. The same HMAC also fetches **OTA feature flags and files** (`GET /v1/config/…`).

There is **no event query API** for apps. Visiting the host in a browser redirects to the marketing site — clients must call `POST /v1/ingest` (and, if you use OTA, the config GETs below).

This package is native only (`ios` / `macos`). Web apps should follow the ingest contract directly (see [Signing](#signing-you-do-not-do-this-yourself)).

---

## 1. Install

Add the Swift package from GitHub:

1. In Xcode: **File → Add Package Dependencies…**
2. Enter `https://github.com/daniel-walsh787/WalshMediaAnalytics_Swift.git`
3. Add the **WalshMediaAnalytics** library to the iOS / Mac app target(s).

Minimum platforms: iOS 17, macOS 14.

Then start once at launch and track events:

```swift
import WalshMediaAnalytics

Analytics.start(.fromInfoPlist())

Analytics.track("app_open")
Analytics.track("button_tap", ["screen": "home"])
```

`env` (`dev` / `testflight` / `prod`) is detected inside the package. You do not pass it unless you need to override.

Call `Analytics.flushNow()` when the scene backgrounds so the last batch leaves before suspend:

```swift
.onChange(of: scenePhase) { _, phase in
    if phase == .background { Analytics.flushNow() }
}
```

Keep a thin per-app `AnalyticsService` (or similar) for named helpers — `flight_logged`, `purchase`, etc. The package should stay generic.

`Analytics.start` creates a process `session_id` and captures device/OS info. Every subsequent `track` (including `app_crash` / `app_hang` / `http_call`) gets these props automatically. Caller keys with the same name win.

| Prop | Meaning |
|---|---|
| `session_id` | UUID for this process launch. Same value on every event until the app is killed. |
| `device_model` | Hardware identifier (`iPad15,3`, `Mac15,7`, simulator model) |
| `device` | Marketing name when known (`iPad Air 11-inch (M3)`), otherwise `device_model` |
| `os_name` | `iOS` / `iPadOS` / `macOS` |
| `os_version` | `26.6` |
| `device_label` | `device` + OS name + version, e.g. `iPad Air 11-inch (M3) iPadOS 26.6` |

---

## 2. Required config

### App slug (`X-App-Id`)

Must match an **active** row in the analytics Worker. One slug per product, shared across that product’s iOS / Mac / web builds:

| Slug | Product |
|---|---|
| `airbook` | AirBook |
| `echomix` | EchoMix |
| `cyoa` | CYOA |
| `trackalog` | Trackalog |
| `macrologiciq` | MacroLogicIQ |
| `pointsy` | Pointsy |
| `safepic` | SafePic |

`appId` also namespaces Keychain / UserDefaults (`com.<appId>.analytics.install`, `<appId>.analytics.pendingEvents`). Use the real slug so installs stay stable. `airbook` keeps existing AirBook device IDs.

### HMAC secret

One secret per **app**, shared across iOS / Mac / web. Lives in `app-hmac-secrets.json` (gitignored) on the Worker side. Put the same value in the app binary via xcconfig → Info.plist — never hard-code it in source, and **never ship `ADMIN_TOKEN`** or call `/v1/admin/*` from an app.

If the secret is empty or still a `$(ANALYTICS_HMAC_SECRET)` placeholder, events queue locally but **nothing is uploaded**. That is intentional for Debug builds without a secret.

### Info.plist + xcconfig

Recommended (same pattern as AirBook):

**Info.plist**

```xml
<key>ANALYTICS_APPNAME</key>
<string>$(ANALYTICS_APPNAME)</string>
<key>ANALYTICS_HMAC_SECRET</key>
<string>$(ANALYTICS_HMAC_SECRET)</string>
```

**xcconfig** — `ANALYTICS_APPNAME` is the ingest slug (`airbook`, `echomix`, …), not the display name. OTA feature flags and files use these same two keys; you do **not** add a tenant slug to xcconfig (the worker returns `tenant_slug` on the manifest).

```
ANALYTICS_APPNAME = echomix
ANALYTICS_HMAC_SECRET = your-app-secret-here
```

Then:

```swift
Analytics.start(.fromInfoPlist())
```

The ingest URL is built into the package (`https://analytics.walshmedia.net.au/v1/ingest`). You can still pass `appId:` to `fromInfoPlist` to override the plist. You can also build `AnalyticsConfiguration` in code (tests, or apps that do not use xcconfig).

---

## 3. Settings

`AnalyticsConfiguration`:

| Field | Default | Purpose |
|---|---|---|
| `appId` | `ANALYTICS_APPNAME` | Slug above. Sent as `X-App-Id`. |
| `ingestURL` | built into the package | `https://analytics.walshmedia.net.au/v1/ingest` |
| `hmacSecret` | from plist | HMAC-SHA256 key. Empty → no flush. |
| `platform` | `ios` or `macos` | Ingest `platform`. Do not send `web` from this package. |
| `reportsCrashes` | `true` | Subscribe to MetricKit and emit `app_crash` / `app_hang` on a later launch. |
| `environment` | built-in detector | Override only if you must force `dev` / `testflight` / `prod`. |
| `userID` | `{ nil }` | Optional stable account id (e.g. CloudKit `userRecordName`). 1–128 chars. **Not** email or name. |

Helpers:

- `AnalyticsConfiguration.fromInfoPlist(userID:…)` — reads `ANALYTICS_APPNAME` / `ANALYTICS_HMAC_SECRET`; env is detected unless you pass `environment:`
- `AnalyticsEnvironment.current()` — same detector, if the host app needs the channel elsewhere
- `AnalyticsConfiguration.ingestEnvironment(fromSignInTier:)` — `development`/`dev` → `dev`, `testflight` → `testflight`, else `prod`

Public API:

```swift
Analytics.start(_ configuration)
Analytics.track(_ name: String, _ props: [String: AnalyticsPropValue] = [:])
Analytics.trackHTTP(endpoint:statusCode:durationMs:timedOut:appResult:extra:logOnlyOnError:)
Analytics.flushNow()
Analytics.OTA.sync()
Analytics.OTA.sync(downloadFiles: .matching { $0 == "airlines.csv" })
Analytics.OTA.refreshFlags()
Analytics.OTA.flag("flag_key")
Analytics.OTA.isEnabled("on_off_flag")
Analytics.OTA.data(for: "path/in/manifest.csv")
Analytics.OTA.data(for: "logos/QF.png", persist: .purgable)
Analytics.Push.registerForRemoteNotifications()  // optional — push only
```

Prop values are `string` / `int` / `bool` only (`AnalyticsPropValue`). Event names are trimmed and must be 1–128 characters; invalid names are dropped.

HTTP calls use a shared `http_call` event (see [HTTP calls](#http-calls)). Prefer `AnalyticsHTTP.data` / `AnalyticsHTTP.Stopwatch` over hand-rolling prop keys so every app lands in the same dashboard columns.

---

## Push notifications (optional)

Push is **fully optional**. Apps that only use analytics and OTA:

- Do **not** need the Push Notifications capability in Xcode
- Do **not** call any `Analytics.Push` methods

Opt in only when you send notifications from the WalshMedia Analytics dashboard **Push Notifications** tab.

```swift
Analytics.start(.fromInfoPlist(userID: { await myAccountId() }))

// Only if this app uses WalshMedia push:
Analytics.Push.registerForRemoteNotifications()
```

Enable the **Push Notifications** capability in Xcode only for apps that call `registerForRemoteNotifications()`.

Forward AppDelegate / notification delegate callbacks (iOS `UIApplicationDelegate` or Mac `NSApplicationDelegate`):

```swift
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Analytics.Push.didRegister(deviceToken: deviceToken)
}

func application(_ application: NSApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Analytics.Push.didRegister(deviceToken: deviceToken)
}

// UNUserNotificationCenterDelegate
func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse,
                            withCompletionHandler completionHandler: @escaping () -> Void) {
    Analytics.Push.handleNotificationResponse(response)
    completionHandler()
}

func userNotificationCenter(_ center: UNUserNotificationCenter,
                            willPresent notification: UNNotification,
                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    Analytics.Push.handleRemoteNotification(userInfo: notification.request.content.userInfo)
    completionHandler([.banner, .sound])
}
```

When a notification arrives, the SDK automatically emits `push_received` with `push_id` (matching `wm_push_id` in the APNs payload). The dashboard shows **Apple** status (APNs accept/reject) and **Device** status (receipt via analytics).

Notification actions from the dashboard:

| Action | Behavior |
|---|---|
| Deep link | Opens a custom URL when the user taps the notification |
| Show alert | Presents an in-app alert with optional cancel and confirm buttons (each can be enabled independently); confirm can deep link or open a URL |

Token registration uses `POST /v1/push/register` with the same HMAC signing as ingest (`{timestamp}.{body}`).

---

## OTA feature flags and files

The same HMAC secret used for ingest also authenticates **OTA config** (`GET /v1/config/{appSlug}/manifest`). Feature flags are always HMAC-protected. Files may be public (CDN / edge-cached) or protected; follow the URLs on the manifest and only sign protected paths (`/v1/config/{appSlug}/files/…`).

No extra Info.plist / xcconfig keys. Empty `ANALYTICS_HMAC_SECRET` disables OTA the same way it disables ingest flush.

```swift
Analytics.start(.fromInfoPlist())

// Small apps: download every file whose disk etag changed.
_ = try await Analytics.OTA.sync()

// Larger catalogs: eager-cache config, leave assets lazy.
_ = try await Analytics.OTA.sync(downloadFiles: .matching {
    $0 == "airlines.csv" || $0 == "logos/list.json"
})

if Analytics.OTA.isEnabled("new_onboarding") {
    // …
}

// Per-environment on/off: `{ "dev": true, "testflight": "yes", "prod": "off" }`
if Analytics.OTA.isEnabled("airline_logos") {
    // on in Debug / TestFlight, off in App Store — no per-env checks in the app
}

// Not an on/off flag — use generic access:
let theme = Analytics.OTA.flag("theme")?.stringValue ?? "system"
let themeAlt = Analytics.OTA.string("theme") ?? "system"
let csv = try await Analytics.OTA.data(for: "airlines.csv")                 // Application Support
let preview = try await Analytics.OTA.data(for: "logos/QF.png", persist: .purgable)  // Caches
let flight = try await Analytics.OTA.data(for: "logos/QF.png", persist: .durable)     // promote if already in Caches

// Flags-only poll (no file downloads):
_ = try await Analytics.OTA.refreshFlags()
```

`sync()` compares each file’s **disk** etag (a sidecar next to the file, e.g. `logos/QF.png.etag`) to the manifest. A manifest-only sync (`downloadFiles: .none`) updates the file list without pretending those bytes were downloaded. `data(for:)` / `file(for:)` then download when the disk etag and manifest etag differ. Re-fetches send `If-None-Match: "{etag}"`; **304** keeps the cached bytes and refreshes the sidecar. A **304** on the manifest itself means flags and the file list are unchanged, so files are not contacted.

`downloadFiles: Bool` still works (`true` → `.all`, `false` → `.none`) but is deprecated.

On a new manifest (not 304), paths that disappeared are pruned from both Application Support and Caches. Paths still listed but never downloaded are left alone.

**Persist** (host policy, not airline-specific):

| `persist` | Read order | After a download |
|---|---|---|
| `.durable` (default) | Application Support, then Caches | Write Application Support; delete the Caches copy |
| `.purgable` | Application Support, then Caches | Write Caches only when Application Support does not already have a current copy |

Last-known flags persist in UserDefaults. Call `Analytics.OTA.flag` / `isEnabled` any time after `start` — they use the cache immediately, even before `sync()` finishes.

**Feature flags.** Dashboard values are JSON. Use two accessors:

| Method | Use when |
|---|---|
| `Analytics.OTA.flag("key")` | Any flag: string, number, object, array. Returns `AnalyticsOTAValue?`. Typed helpers: `string`, `int`, `bool`, `double`, `json`. |
| `Analytics.OTA.isEnabled("key")` | The flag is an on/off switch (you know the schema). |

`isEnabled` understands:

- A single value: JSON `true` / `false`, or the strings `true`/`false`, `enabled`/`disabled`, `yes`/`no`, `on`/`off` (case-insensitive).
- A three-channel object with **exactly** those keys, each an on/off token:

```json
{ "dev": true, "testflight": "yes", "prod": "off" }
```

The channel object is evaluated with the same `dev` / `testflight` / `prod` detector as ingest. You do not branch on environment in the app. A theme string like `"dark"` is **not** on/off — use `flag("theme")` / `string("theme")`. `{ "enabled": "yes", "variant": "b" }` still reads the `enabled` key from `isEnabled`.

`sync()` and `refreshFlags()` resolve and cache environment before they return, so a check immediately after those calls is correct. `Analytics.start` also kicks off the same detector in the background.

**HTTP (OTA)**

| Status | Package action |
|---|---|
| `200` | Parse manifest / flags, or store file bytes and etag |
| `304` | Keep the cached snapshot or file |
| `401` / `403` | Throw `unauthorized` — fix slug / HMAC; do not retry in a loop |
| `402` | Throw `quotaExceeded` — pause config reads (same credit wallet as ingest) |
| `404` | Throw `notFound` |
| Transport / other | Throw; previous cache is left in place |

Signing for config GETs is HMAC-SHA256 of `config:GET:{path}` (the percent-encoded request path, e.g. `/v1/config/echomix/manifest`), sent as `X-App-Id` + `X-Signature`. This is not the ingest `{timestamp}.{body}` form.

The tenant slug shown on the dashboard OTA Config tab (`walshmedia`, …) is **not** `ANALYTICS_APPNAME`. It only appears in public file URLs. Apps that call `sync()` never need to put it in xcconfig.

---

## 4. Event names

Convention: **snake_case verb or noun_verb**. Put detail in `props`, not in the name.

Suggested shared names:

| Name | When | Useful props |
|---|---|---|
| `app_open` | Cold start and returning to `.active` | — |
| `app_background` | Scene backgrounded (optional; flush already runs) | — |
| `screen_view` | A screen became visible | `screen` |
| `button_tap` | Primary controls | `screen`, `button` |
| `purchase` | Successful IAP | `product` |
| `error` | Handled failure you care about | `code`, `area` (no message dumps with PII) |
| `http_call` | An outbound HTTP (or HTTP-like) request finished | `endpoint`, `http_status`, `duration_ms`, `timed_out`, `app_result` |
| `app_crash` | MetricKit crash (automatic) | `exception_type`, `exception_code`, `exception_name`, `signal`, `signal_name`, `reason`, `exception_message`, `version`, `build`, `stack`, `stack_app`, `binary_uuid`, `stack_truncated` |
| `app_hang` | MetricKit hang (automatic) | `hang_ms`, `version`, `build`, `stack`, `stack_app`, `binary_uuid`, `stack_truncated` |

Product-specific names are fine (`flight_logged`, `backup_created`). Keep them stable — the dashboard groups by exact string.

**Do not** put PII in `name` or `props`: no email, person name, exact GPS, tokens, roster/employee IDs, or raw file paths. Prefer integer remote ids or coarse enums (`airline: 1`).

Timestamps are Unix **seconds**. Each event gets a client UUID so a retried flush is stored once (`INSERT OR IGNORE` on `(app, id)`).

---

## HTTP calls

Log outbound requests with **`http_call`**. The prop keys are fixed so AirBook, EchoMix, and the rest can share one query.

| Prop | Type | When |
|---|---|---|
| `endpoint` | string | Stable id you choose (`naips.briefing`, `subscription.session`). Not a full URL (query strings often have tokens / PII). Max 128 chars. |
| `http_status` | int | HTTP response code. Omit when there was no response. |
| `duration_ms` | int | Round-trip time. **Omit when `timed_out` is true.** |
| `timed_out` | bool | Always set. |
| `app_result` | `success` / `error` | Optional. Use when HTTP 200 is not enough (`{"status":"error"}`, empty body, login rejected, …). |

Drop-in for `URLSession`:

```swift
let (data, response) = try await AnalyticsHTTP.data(
    for: request,
    endpoint: "contact.submit"
) { data, http in
    AnalyticsHTTPAppResult.fromJSONStatus(data)
        ?? ((200...299).contains(http.statusCode) ? .success : .error)
}
```

High-volume assets (remote images) should pass `logOnlyOnError: true` so 2xx successes are skipped. Timeouts, transport errors, non-2xx statuses, and `app_result: .error` still emit:

```swift
try await AnalyticsHTTP.data(
    from: imageURL,
    endpoint: "airline.logo",
    logOnlyOnError: true
) { data, http in
    guard (200...299).contains(http.statusCode) else { return .error }
    return isValidImage(data) ? .success : .error
}
```

For WKWebView, completion-handler sessions, or anything else you time yourself:

```swift
let http = AnalyticsHTTP.Stopwatch()
do {
    let result = try await fetchRoster()
    http.track(endpoint: "jetstar.roster", appResult: .success)
    return result
} catch {
    http.track(endpoint: "jetstar.roster", error: error)
    throw error
}
```

Pass `timedOut: true` on the stopwatch when your own timeout is not a `URLError.timedOut` (WKWebView navigation deadlines). Do not wrap the analytics ingest `URLSession` call — that would recurse.

---

## 5. What the package already does

You do not implement signing, batching, or retries.

**Flush when** the network is available **and** 20 events are queued, 60 seconds have passed, the app calls `flushNow()` (background), or `NWPathMonitor` reports the path is satisfied again. Offline: events stay in UserDefaults; **no HTTP**. Coming online (including next launch with connectivity) drains the whole queue in batches of at most 100 events / 256 KB (halves a batch if it is over the body cap).

**OTA:** `Analytics.OTA.sync()` loads the signed manifest, caches flags, and downloads files whose disk etag changed (or that return 304). Use `downloadFiles: .matching` to eager-cache a subset. See [OTA feature flags and files](#ota-feature-flags-and-files).

**HTTP**

| Status | Package action |
|---|---|
| `202` | Drop those events and send the next batch until the queue is empty |
| `429` / transport error while online | Keep them; exponential backoff (15s → 5 min) |
| No network path | Keep them; do not retry until the path is satisfied |
| `400` / `401` / `403` | Drop the batch (bad payload / bad HMAC / app disabled). Fix config; do not spin-retry. |

The Worker also rate-limits **10 requests / minute / IP**. Office NAT shares an IP — prefer fewer, larger flushes.

**Signing:** Send `X-Timestamp` (Unix seconds). HMAC-SHA256 of `{timestamp}.{rawBody}` (exact body bytes after the dot), lowercase hex, as `X-Signature`. The encoder uses sorted keys and no pretty-print so the bytes that are signed are the bytes that are sent. Do not re-serialize after signing. Legacy body-only HMAC (no `X-Timestamp`) still works on the Worker during migration; this package always uses the timestamped form.

**Install id:** Keychain UUID per install (not IDFV-as-PII, not Apple ID). Fallback UserDefaults, then migrate into Keychain.

**Crashes:** MetricKit diagnostics arrive on a **later launch**. `stack` is unsybolicated (`AirBook+0x1a2b`). `stack_app` is app-binary frames with `binaryUUID` (`AirBook+0x9e6cc8@UUID`) so a matching dSYM can be used with `atos`. `binary_uuid` is the app frame UUID. Jetsam / some watchdog kills may not appear. This is not Crashlytics.

**Limits (Worker):** body ≤ 256 KB; ≤ 100 events; each `props` JSON ≤ 8192 bytes; `device_id` / event `id` / `name` 1–128 chars.

### Not for apps

| Endpoint | Purpose |
|---|---|
| `GET /v1/admin/export` | PC sync + `ADMIN_TOKEN` |
| `POST /v1/admin/export/ack` | Delete synced rows after a pull |
| `GET /v1/admin/stats` | Backlog size |

Do not call these from iOS, Mac, or web clients.

### Adding a new product

1. Add the slug + HMAC secret on the Worker (`app-hmac-secrets.json` + D1 `active` app).
2. Use that slug as `appId`.
3. Ship the secret via xcconfig. Empty secret = local queue only.

---

## 6. Environment detection

Ingest `env` is one of `dev`, `testflight`, or `prod`. It is **not** a privacy identifier — it only buckets events so TestFlight noise does not land in production dashboards.

The package detects this itself (`AnalyticsEnvironment.current()`). Host apps should **not** hard-code `"prod"`. StoreKit sandbox is only a *positive* TestFlight signal — a production `AppTransaction` does **not** mean this binary is App Store. TestFlight testers who originally installed from the App Store often have production App Transactions and production subscription entitlements. Detection ORs several signals and treats **any** TestFlight hit as TestFlight, then caches the result for the process.

| Order | Check | Result |
|---|---|---|
| 1 | `DISTRIBUTION_CHANNEL=direct` (Sparkle / notarized Mac) | `prod` |
| 2 | Plist `ANALYTICS_ENV` or `AIRBOOK_SIGN_IN_TIER` (`dev` / `development` / `testflight` / `prod` / `production`) | that value |
| 3 | `#if DEBUG` | `dev` |
| 4 | Signed `beta-reports-active` entitlement in the Mach-O code signature (Apple strips `embedded.mobileprovision` from TestFlight; `SecTask` is not in the iOS SDK) | `testflight` |
| 4 | Embedded profile contains `beta-reports-active` (`embedded.mobileprovision` or `embedded.provisionprofile`) | `testflight` |
| 4 | App Store receipt file is named `sandboxReceipt` (or that file exists next to `receipt`) | `testflight` |
| 4 | `AppTransaction.environment` is `.sandbox` or `.xcode` (local read first; `refresh()` only if needed, so offline still works) | `testflight` |
| 4 | Any verified StoreKit `Transaction.currentEntitlements` is sandbox / Xcode | `testflight` |
| 5 | Otherwise | `prod` (not cached if StoreKit did not return an environment, so the next flush can retry) |

Mac App Store is `platform: macos` + `env: prod`. Leave the override empty unless you are debugging:

```
ANALYTICS_ENV =
```

Pass `environment:` on `AnalyticsConfiguration` only if you must force a value. AirBook uses the built-in detector.

---

## 7. Privacy policy and terms of service

This is documentation for writing your app’s privacy policy / App Store answers, not legal advice. The host app is the data controller for whatever it chooses to track. Walsh Media operates the ingest service.

### Where data goes

Events are `POST`ed to **`https://analytics.walshmedia.net.au/v1/ingest`**. That host is a Walsh Media service running on **Cloudflare** (Cloudflare Workers and related Cloudflare infrastructure). Traffic therefore reaches Cloudflare’s network; Cloudflare may process connection metadata (including IP address) as part of providing HTTPS, DDoS protection, and the Worker’s **10 requests / minute / IP** rate limit.

There is no client query API for events. Apps send analytics; they do not read other users’ events back. OTA config is a separate, HMAC-signed read of **your** flags and files.

Do not describe this as Apple Analytics, Google Analytics, or a third-party ad network. It is first-party product analytics operated by Walsh Media.

### What the package always transmits (when a secret is configured)

Each flush is one JSON batch:

| Field | What it is | What it is not |
|---|---|---|
| `platform` | `ios` or `macos` | A user identifier |
| `env` | `dev` / `testflight` / `prod` | A user identifier |
| `device_id` | Random UUID generated on first launch, stored in the Keychain (UserDefaults fallback). Stable **per install**, namespaced by `appId` | IDFV, IDFA, Apple ID, email, or name. Reinstall (or a new `appId`) creates a new id |
| `events[].id` | Random UUID so retries are deduplicated | A user identifier |
| `events[].name` | Event name you passed to `track` (or `app_crash` / `app_hang`) | — |
| `events[].ts` | Unix time in seconds | — |
| `events[].props` | Optional string / int / bool map you passed, plus automatic `session_id` / device / OS fields | Omitted when empty |

Automatic event props (set on `Analytics.start`, merged into every event; caller keys win):

| Prop | What it is |
|---|---|
| `session_id` | Random UUID for this process. Not stable across launches |
| `device_model` | Hardware identifier (`iPad15,3`) |
| `device` | Marketing name when known |
| `os_name` / `os_version` | e.g. `iPadOS` / `26.6` |
| `device_label` | Combined display string |

Headers: `X-App-Id` (product slug), `X-Timestamp` (Unix seconds for the signed payload), and `X-Signature` (HMAC of `{timestamp}.{body}` — not a user secret).

OTA config GETs to the same host send `X-App-Id` and `X-Signature` (HMAC of `config:GET:{path}`). They do not send `device_id` or event payloads. Cached flags and files stay on device.

If `ANALYTICS_HMAC_SECRET` is empty, **nothing is uploaded**. Events may still sit in UserDefaults on device. OTA `sync()` throws `notConfigured`.

### Optional `user_id`

`user_id` is **off by default**. It is sent only if the host app supplies `userID:` (AirBook uses CloudKit `userRecordName`). Rules:

- 1–128 characters; invalid values are dropped
- Attached to the **batch**, not to each event
- Must be a stable opaque account key (CloudKit record name, your own account UUID)
- **Must not** be email, person name, phone number, or any other direct identifier

If you pass `user_id`, say so in the privacy policy: you can join analytics events to an account across reinstalls / devices that share that account. If you omit it, events are install-scoped via `device_id` only.

### What you can transmit (host-app responsibility)

Anything you put in `track(_:_:)` names and props is stored as analytics. The package does not scan for PII. **Do not send** email, names, exact GPS, auth tokens, roster/employee IDs, file paths, or message contents. Prefer coarse enums and integer remote ids.

With `reportsCrashes` (default **on**), MetricKit may later send:

- `app_crash` — Mach exception type/code/name, signal name, termination reason and (iOS 17+) Objective-C/Swift exception message, marketing version + build, unsybolicated `stack`, app-only `stack_app` with binary UUID
- `app_hang` — hang duration, version, build, same style of stack

`stack` is truncated on a frame boundary (~4 KB / 48 frames). `stack_truncated` is set when frames or bytes were dropped. Turn this off with `reportsCrashes: false` if a given app should not collect crash diagnostics.

### Suggested privacy-policy wording (adapt as needed)

You can say that the app sends product-analytics events (feature use, and optionally crash/hang diagnostics) to Walsh Media at `analytics.walshmedia.net.au`, hosted on Cloudflare; that an install-scoped random id is used; that an optional account id may be included if the user is signed in to iCloud / your account system; and that you do not sell this data for advertising.

### App Store nutrition labels

Declare what you actually collect. Typical answers when using this package as designed:

| Apple category | Usually |
|---|---|
| Product Interaction | Yes (event names / props you choose) |
| Crash Data | Yes if `reportsCrashes` is left on |
| User ID | Yes only if you pass `userID` |
| Device ID | The install UUID is not IDFA. Treat as a product analytics identifier, not tracking across other companies’ apps |
| Precise Location | No, unless **you** put coordinates in props |
| Contact Info | No, unless **you** put it in props |

Used for **App Functionality** / **Analytics**, not Third-Party Advertising. This package does not include a `PrivacyInfo.xcprivacy` manifest — add one on the **app** target if Apple requires it for these data types.

### Terms of service

If your ToS mentions third-party processors, list Walsh Media (analytics) and Cloudflare (hosting / edge). Users are not creating an account on the analytics host; the Worker only accepts signed ingest from your apps.
