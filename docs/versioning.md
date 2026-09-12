# Version numbering (this fork)

This repository is a fork of [g8row/PhotosBackup](https://github.com/g8row/PhotosBackup). Use a four-segment marketing version so fork-only work stays distinguishable from upstream, and so the last segment can reset when the upstream base changes.

## Scheme

`MARKETING_VERSION` is `{upstream}.{forkPatch}`:

| Situation | Example |
| --- | --- |
| First fork release on top of upstream `0.3.6` | `0.3.6.1` |
| Further fork-only changes | `0.3.6.2`, `0.3.6.3`, … |
| After pulling or merging a new upstream base (e.g. `0.3.7`) | Restart at `0.3.7.1` |

The first three segments always match the upstream marketing version this tree is based on. Increment only the last segment for work that is not an upstream version bump. When the upstream base changes, set the last segment back to `1`.

`CURRENT_PROJECT_VERSION` stays a monotonic integer, independent of the fourth marketing segment. Increment it by 1 on every versioned release (fork-only or after merging upstream).

## How to bump

1. Edit `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in [`project.yml`](../project.yml). That file is the source of truth.
2. Run `xcodegen generate` so the generated Xcode project picks up the new values.
3. Keep the README “Latest release” line in sync with `MARKETING_VERSION`, and note the upstream base when it differs.
4. Add a `[x.y.z.n]` section to [`CHANGELOG.md`](../CHANGELOG.md). Record only this fork’s changes. After pulling a new upstream base, add one line that names that upstream version — do not copy upstream’s notes.

Do not copy upstream’s three-segment `x.y.z` into this fork’s marketing version.

If this fork publishes a GitHub release, tag it with the four-segment marketing version (for example `0.3.6.1`).
