# .agents — quick intro for AI agents

Start here. Read this file + `architecture.md` + `build-test.md` before touching code.

## 60-second overview

Experimental on-device iPhone app (**Photos Backup**, Xcode target `PhotosBackup`)
that backs up Photos library items to Google Photos via private `photos.native`
endpoints + Android-style auth. SwiftUI app + bundled Safari web extension.
No backend. Swift 5.9, iOS 16.0+, XcodeGen-generated Xcode project.

## Map

| File | What |
| ---- | ---- |
| `README.md` | Full product + install docs (source of truth for behavior) |
| `.agents/architecture.md` | Repo layout, key types, data flow |
| `.agents/build-test.md` | xcodegen / xcodebuild / simctl commands |
| `.agents/auth-flow.md` | oauth_token → master token → Photos credential (single-use! live-token rules) |
| `.agents/guardrails.md` | What NOT to do (security, signing, background limits) |
| `docs/ADR-001-auth-route.md` | Auth design rationale + SideStore tradeoffs |
| `docs/feasibility-probe.md` | Protocol details |
| `docs/versioning.md` | Fork versioning: `{upstream}.{forkPatch}`; reset last segment on upstream bump |
| `CHANGELOG.md` | Fork-only changes; do not copy upstream notes |

## App identity (don't change casually)

- App bundle ID: `com.g8row.photosbackup`, Extension: `... .extension`
- App Group: `group.com.g8row.photosbackup`
- URL scheme: `photosbackup://`, BG task: `com.g8row.photosbackup.background-backup`

## First actions for a new task

1. `xcodegen generate` — project is generated from `project.yml`, never edit `.xcodeproj` by hand.
2. Find code via `architecture.md` table, not glob-spam.
3. Offline tests are the default gate; live Google tests are opt-in (see `build-test.md`).
