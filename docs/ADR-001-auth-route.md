# ADR-001 — Authentication route for the iOS GPMC uploader

Status: proposed (pending the feasibility-probe result)
Date: 2026-09-08

## Context

GPMC authenticates to Google Photos' private `photos.native` API with an
Android-style master token. Its README obtains that token from a rooted /
emulated Android device. The companion project **gotohp**
(`0637c745dc590d74766b24eac80d689d2248e766`) removed the Android requirement:
it signs in on Google's `EmbeddedSetup` web page, reads the `oauth_token`
cookie, and exchanges it server-side for the master token and then a Photos
credential.

We want the same account onboarding to happen entirely on an iPhone.

## Decision

Target a **standalone SwiftUI iPhone app** (no companion server or desktop
process during normal operation) that authenticates via the gotohp browser
flow, with a **bundled Safari web extension** capturing the `oauth_token`
cookie so the user never touches developer tools.

Concrete parameters:

| Item | Choice | Rationale |
|---|---|---|
| Minimum iOS | 16.0 | Safari web extensions with MV3 + `browser.cookies`; `NavigationStack`. Revisit to 17 only if a needed API forces it. |
| Auth route | Safari extension → `oauth_token` → gotohp exchange | Only route that keeps full GPMC functionality *and* can run on-device. Public Photos API scopes are not equivalent and are a separate product decision. |
| Handoff (extension → app) | App Group when the signing team can provision it, `photosbackup://` URL otherwise | Both are implemented and selected at runtime. **Superseded 2026-09-08** — the original "URL handoff must not ship" no longer holds; see Distribution below. |
| Distribution | Unsigned `.ipa`, sideloaded with SideStore (`Scripts/make-ipa.sh`) | No App Store review, no paid membership required. SideStore re-signs on device with the user's Apple ID. |
| Upstream refs | GPMC `94b1b267…` for protocol; gotohp `0637c745…` for auth + protocol fixes | Preserve MIT notices from both. |
| First-release scope | Account connect + explicit photo/video upload + activity queue. Live Photos now use gotohp’s linked create/reconcile commit. Background transfer hardening and Android-credential import (incl. token binding) remain follow-ups. | Keep the first release provable end to end. |

## Open question this ADR is blocked on

Does mobile Safari on `accounts.google.com/EmbeddedSetup` receive an
`oauth_token` cookie, and does the exchange succeed from an iOS-originated
request? The `PhotosBackup` target exists to answer exactly this. If the
answer is no, the fallback is a one-time manual `oauth_token` / `auth_data`
import under advanced setup (already sketched in `GPMCClient.AuthData`).

**Status 2026-09-08 (attempt 5): answered yes; the decision stands.** All nine
checklist steps pass on an **unsigned simulator build** — EmbeddedSetup issues an
`oauth_token` to mobile Safari, the extension reads it (`httpOnly`, so only the
`cookies` API could), the app ingests it single-use, and it exchanges into a
master token, a Photos access token, and a successful `photosdata-pa` call. The
consent screen renders on a mobile UA; no desktop-UA override is needed. **No
`TokenEncrypted=1`**, so token binding does not need porting.

Attempt 1's conclusion that "a real Apple Developer team is probably needed even
to evaluate this route" was **wrong**, and is retracted. Both blockers were bugs
in this port: the extension queried only the default cookie store (iOS Safari
partitions them), and a refactor had dropped the request body so every protobuf
RPC posted zero bytes. Neither was an entitlement problem.

A team is still required to **ship**: the App Group handoff and the Keychain both
need one. Without it the credential cannot be persisted, so a connected account
is session-only — surfaced as a warning, not a rejection.

## Distribution: SideStore sideload (2026-09-08)

Target is an unsigned `.ipa` that SideStore re-signs on device. That choice has
teeth, because a **free personal team cannot provision App Groups** — the
capability is restricted to paid Apple Developer Program membership, along with
push, iCloud, associated domains and Sign in with Apple.

Consequences, in descending order of how much they hurt:

1. **The `photosbackup://` URL handoff becomes the shipping channel**, not a probe
   fallback. The App Group path stays in the code and is preferred whenever the
   entitlement provisions, so a paid-team build is unaffected.
2. **The URL channel is weaker than the App Group one.** It carries a live,
   single-use `oauth_token` through a custom scheme, and iOS scheme registration
   is not exclusive: another installed app registering `photosbackup` could receive
   the token. The exposure is one single-use token that the app consumes
   immediately, but it is a real difference and is accepted deliberately for a
   personal sideload. It should be reconsidered before any wider distribution.
3. **A free-team build expires every 7 days** and must be refreshed. SideStore
   automates this, but the app must tolerate being re-signed — nothing may
   assume a stable signing identity. The Keychain record survives a refresh only
   while the team and bundle ID are unchanged; treat "connect the account again"
   as a normal, expected path rather than an error state.
4. **The Safari extension needs its own App ID**, so app + extension consume two
   of the free account's limited slots.
5. **The Keychain works once signed at all**, free team included — the
   entitlement gap that made the credential session-only on the simulator is not
   a paid-membership problem.

If a paid membership is available, none of 1-4 apply and the App Group path is
the better one; the code needs no change either way.

## Consequences

- The app carries a Safari web extension target and its review surface.
- Token binding (`TokenEncrypted=1`) is explicitly detected and rejected for
  now, not silently mishandled — see `TokenExchange` and `GPMCClient`.
- Shipping via SideStore requires only a free Apple ID, at the cost of the
  weaker URL handoff and a 7-day refresh cycle. A paid team buys back the App
  Group channel and a year between refreshes.

## Update 2026-09-08 — route changed to an in-app WKWebView (iOS 17 regression)

**Symptom.** On **iOS 17** the Safari extension reports "no completed sign-in":
`browser.cookies` returns only non-HttpOnly cookies, so the HttpOnly
`oauth_token` is invisible. The route's every prior "pass" (attempts 1–5) was on
an **iOS 18.6** simulator, where the extension `cookies` API *does* return
HttpOnly cookies. So the capture mechanism was iOS-18-only the whole time.

**Evidence (same iOS 17.2 device).** Safari's real cookie jar for
`accounts.google.com` held `__Host-GAPS` (httpOnly), `NID` (httpOnly) and `OTZ`
(not httpOnly). The extension's `cookies.getAll` returned **only `OTZ`** — the
two HttpOnly cookies were filtered out. A planted non-HttpOnly cookie
round-tripped fine, confirming the filter is specifically on HttpOnly.

**Decision.** Drop the Safari web extension. Host `EmbeddedSetup` in an in-app
`WKWebView` and read `oauth_token` from the view's own
`WKHTTPCookieStore.getAllCookies()`, which returns HttpOnly cookies on iOS
16/17/18 alike (the app owns the store; no extension sandbox filtering applies).

**Validated on iOS 17.2**, same device that failed with the extension: a plain
`WKWebView` with a full mobile-Safari user agent runs the real
`EmbeddedSetupAndroid` flow (no "browser may not be secure" block), and after
**I agree** `getAllCookies()` returned `oauth_token` (httpOnly, len 80) plus
`user_id`. `TokenExchange` is unchanged.

**Consequences.**
- Minimum iOS returns to a clean **16.0** — no iOS-18 floor needed.
- The `photosbackup://` URL handoff and the App Group channel are **gone**, and
  with them the URL-scheme token-exposure risk (Distribution risk #2 above).
- New: `AccountConnectView` (`App/Sources/AccountConnectWebView.swift`). The
  connect step in onboarding, the Settings sheet, and Diagnostics all present it.
- **Removed** (follow-up commit): `Extension/`, `HandoffStore`, the
  `AccountConnector.handle(_:)` handoff path, the `photosbackup` URL type in
  `Info.plist`, and the App Group entitlement (`CODE_SIGN_ENTITLEMENTS` dropped
  from `project.yml`). The app no longer declares any App Group or custom URL
  scheme.
