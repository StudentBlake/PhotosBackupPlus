# Changelog

Changes made in this fork, on top of [g8row/PhotosBackup](https://github.com/g8row/PhotosBackup).

Upstream release notes are not copied here. When this tree pulls or merges a new upstream base, that is recorded as a single entry (for example “Pulled upstream 0.3.7”). See [docs/versioning.md](docs/versioning.md) for how the four-segment version is assigned.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.3.6.2] — 2026-09-12

### Added

- An in-progress backup keeps preparing for leftover iOS time after lock or app switch, then hands more file PUTs to the background session.
- On iOS 26, **Back Up Now** and **Re-check Backups** can continue for minutes with a system progress indicator the user can cancel.
- Dashboard and Activity distinguish items transferring in iOS from items waiting for another execution window.

### Fixed

- Leaving the app no longer cancels local-file work that was already exporting, hashing, preparing, or committing. New iCloud originals still wait until the app is open.

## [0.3.6.1] — 2026-09-12

### Added

- Live Photos upload as a still plus motion pair, with **Update Existing Photos to Live** and **Incomplete Live Photos** settings.
- Four-segment fork versioning (`{upstream}.{forkPatch}`) so fork-only releases stay distinguishable from upstream.

### Changed

- `Scripts/make-ipa.sh` picks a usable Xcode `DEVELOPER_DIR` when one is not already set.

## [0.3.6] — 2026-09-10

### Changed

- Based on [upstream 0.3.6](https://github.com/g8row/PhotosBackup/releases/tag/0.3.6).
