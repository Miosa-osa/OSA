# OSA Release SOP

How to ship an OSA release without breaking installers. Read the Golden Rules; follow the checklist.

## Golden rules (never break these)

1. **Never tag red code.** `release.yml` builds and publishes installers on any `v*.*.*` tag with **no test gate**. A tag on a red commit ships broken binaries to everyone. Confirm CI is green on `main` *before* tagging.
2. **Three numbers must match:** the `VERSION` file, `priv/rust/tui/Cargo.toml` `version`, and the git tag. Any drift fails CI's version-source guard or ships a mislabeled binary.
3. **Release from `main`, only when it's green.** Never tag a feature/fix branch directly.
4. **Batch changes into one release.** Every tag ≈ 15 min of runner time (macOS bills at 10×). Don't micro-release.

## What a release actually is

Pushing a tag `v1.0.xxx` triggers `.github/workflows/release.yml`, which:
- builds 3 platform artifacts in parallel — `linux-x64`, `macos-arm64`, `windows-x64` — plus the Rust TUI binary,
- publishes them as GitHub Release assets (what `scripts/install.sh` downloads).

Wall-clock ≈ 7 min, gated by the slowest lane (Windows). Fully automatic — no local build. Local cross-compile is unsupported by design (`mix.exs`).

## Pre-flight checklist (before you tag)

- [ ] All changes merged to `main` via PR.
- [ ] CI green on `main` — Elixir suite **and** Rust TUI suite both ✓: `gh run list -R Miosa-osa/OSA -b main -L 3`
- [ ] `VERSION` bumped to the new number.
- [ ] `priv/rust/tui/Cargo.toml` `version` == `VERSION`; run `cargo update -p osa-tui` (from `priv/rust/tui`) to sync the lockfile.
- [ ] Release notes / CHANGELOG updated.
- [ ] Local sanity: `mix compile` clean, `mix test` green (discount known env-only failures — see below).

## Cut the release

1. Bump the version (one commit):
   - `VERSION` → `1.0.xxx`
   - `priv/rust/tui/Cargo.toml` → `version = "1.0.xxx"`, then `cargo update -p osa-tui`
   - `git commit -am "release: v1.0.xxx"`
2. Open a PR to `main`, wait for **green CI**, merge.
3. Tag (must equal the `VERSION` file) and push:
   ```sh
   git checkout main && git pull
   git tag v1.0.xxx
   git push origin v1.0.xxx
   ```
4. Watch the build: `gh run list -R Miosa-osa/OSA -w Release -L 1`, then `gh run watch <run-id> -R Miosa-osa/OSA`.

## Verify the release

- `gh release view v1.0.xxx -R Miosa-osa/OSA` — all assets present (3 OS archives + `.sha256` + TUI binaries).
- `gh run list -R Miosa-osa/OSA -w Release -L 1` — every lane ✓.
- Smoke test: download one artifact, run it, confirm the version it reports == `1.0.xxx`.

## If it goes wrong (rollback)

```sh
gh release delete v1.0.xxx -R Miosa-osa/OSA --yes
git push origin :refs/tags/v1.0.xxx        # delete the remote tag
```
Then **fix forward** — never re-tag the same number; bump to the next patch.

## Cost awareness

- Each tag ≈ 3 platform builds + publish ≈ ~15 min billed runner time.
- **macOS bills at 10×, Windows 2×, Linux 1×.** The macOS lane is the biggest cost.
- Every push to `main` and every PR also runs full CI (~8 min). Batch work; don't tag per commit.

## Known failure modes (learned the hard way)

- **Cargo ↔ VERSION drift** → Rust `config::version_source_tests` fails CI. Sync both, every time.
- **Tag ≠ VERSION** → mislabeled or rejected build.
- **No CI gate on `release.yml`** → a red tag still ships broken installers. Interim rule: a human confirms green before tagging. Permanent fix: gate the `publish` job on a green CI `workflow_run` for the tagged SHA and on all build lanes succeeding (drop `if: always()`).
- **`osa update` banner shows a phantom newer version** → the local update check reads git tags from the *current directory*; run inside another repo it reports that repo's tags. Only trust it inside the OSA checkout (now guarded by an origin-identity check).
