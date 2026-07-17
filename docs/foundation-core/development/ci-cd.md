# CI/CD Pipeline

Audience: contributors who need to understand when and how release artifacts are built and published.

## Overview

OSA has two GitHub Actions workflows in `.github/workflows/`:

| Workflow | File | Trigger |
|---------|------|---------|
| Release | `release.yml` | Push of a `v*.*.*` tag |
| Pull Request Labeler | `labeler.yml` | Pull request opened/updated |

`labeler.yml` only applies path-based labels to PRs — it builds nothing. There is no continuous-integration workflow that runs the test suite on pull requests or pushes to `main`. Contributors must verify `mix test` and `mix format` locally before opening a PR.

## Release Workflow (`release.yml`)

### Strategy

Each release ships **prebuilt, zero-toolchain artifacts** so end users need no language toolchain installed:

- A self-contained Elixir **OTP release** assembled with `mix release osagent`. `include_erts` defaults to `true`, so the tarball bundles its own ERTS — the machine needs no Erlang or Elixir installed.
- The prebuilt **Rust TUI** binary (`priv/rust/tui`, built with `cargo build --release`).

Both are uploaded as GitHub Release assets so `scripts/install.sh` / `scripts/install.ps1` can download them directly.

### Trigger

Any push to a tag matching `v*.*.*`:

```bash
git tag v1.0.003
git push origin v1.0.003
```

### Environment Versions

```yaml
MIX_ENV:        prod
ELIXIR_VERSION: "1.17.3"
OTP_VERSION:    "26.2.5"
```

OTP is pinned to **26.2.5**, not 27. OTP 27 has Mix-release bugs (`TypedStruct.MixProject` / `Decimal.Error` "already compiled" during the dep walk) and `erlexec` is pinned to `2.0.6` (the last pre-OTP-27 release) in `mix.exs`. The build stays on OTP 26 until those land.

### Jobs

Three platform build jobs run in parallel, followed by a `publish` job.

| Job | Runner | Artifact |
|-----|--------|----------|
| `build-linux-x64` | `ubuntu-22.04` | `osa-linux-x64.tar.gz` + `osagent-tui-linux-x64` |
| `build-macos-arm64` | `macos-14` (Apple Silicon) | `osa-macos-arm64.tar.gz` + `osagent-tui-macos-arm64` |
| `build-windows-x64` | `windows-latest` | `osa-windows-x64.zip` + `osagent-tui-windows-x64.exe` |

Linux x64 is the primary target. macOS and Windows are secondary — the `publish` job attaches their assets if present but does not fail the release if one of them fails to build.

Each build job runs these steps:

1. Checkout source at the tag.
2. Set up Erlang/OTP 26.2.5 and Elixir 1.17.3 via `erlef/setup-beam@v1`.
3. Restore the `deps` + `_build` cache (keyed on `mix.lock`).
4. On Linux, install the system libraries the Rust TUI links against (`pkg-config`, `libssl-dev`, the `libxcb*` set, `libasound2-dev`, `libonig-dev`). macOS and Windows runners ship Rust and these libraries already.
5. Install Elixir production deps: `mix deps.get --only prod`.
6. **Stamp the version from the git tag** (see below).
7. Assemble the OTP release: `MIX_ENV=prod mix release osagent --overwrite`.
8. Package the release: `tar -czf osa-{platform}.tar.gz` from `_build/prod/rel/osagent/` (Windows packages a `.zip` via `Compress-Archive` so `install.ps1`'s `Expand-Archive` works).
9. Build the Rust TUI: `cargo build --release` in `priv/rust/tui`, then copy the binary to `dist/osagent-tui-{platform}`.
10. Upload everything in `dist/` as a workflow artifact.

### Version Stamping

The git tag is the single source of truth for the version:

- The **tag itself** (padded display form, e.g. `v1.0.003`) is authoritative for the tag name and the GitHub Release title — those stay padded.
- For the **build**, the tag is normalized to valid semver (strip a leading zero from the patch: `v1.0.003` → `1.0.3`). semver forbids leading zeros, so `mix`/`cargo` would reject `1.0.003`. The normalized value is exported as `OSA_VERSION`, written into the `VERSION` file that `mix.exs` reads at compile time, and the in-app display re-pads it at render time so the operator still reads the padded form everywhere.

Any cached, stale `optimal_system_agent.app` is deleted before `mix release` so a restored build cache cannot ship an old `vsn` to `Application.spec/2`.

### `publish` Job

Runs on `ubuntu-22.04` after all three build jobs (`needs: [build-linux-x64, build-macos-arm64, build-windows-x64]`, `if: always()` so a single failed platform does not sink the release). It:

1. Downloads every build artifact.
2. Flattens them into `release-assets/` and computes a `.sha256` sidecar for each archive (`*.tar.gz`, `*.zip`) so `install.sh` / `install.ps1` can verify integrity.
3. Creates the GitHub Release via `softprops/action-gh-release@v2` with `generate_release_notes: true`. A tag containing `-` is marked `prerelease`.

### Artifact Storage

Assets are attached directly to the GitHub Release. There is no separate artifact store or container registry.

## Releasing a New Version

1. Update the `VERSION` file (current: `1.0.3`):
   ```bash
   echo "1.0.3" > VERSION
   git add VERSION
   git commit -m "[chore] Bump version to 1.0.3"
   ```
2. Push the commit to `main`.
3. Tag (padded display form) and push:
   ```bash
   git tag v1.0.003
   git push origin main
   git push origin v1.0.003
   ```
4. Watch the `Release` workflow at `github.com/Miosa-osa/OSA/actions`.
5. When the three build jobs finish, `publish` attaches the assets and creates the Release.

## What Is Not Automated

- **Test runs on PRs** — no CI job runs the suite automatically. Contributors run `mix test` locally.
- **Linting** — `mix format` is not enforced by CI. Run it before committing.
- **Homebrew tap** — there is no `update-homebrew.yml` workflow. Distribution is via the GitHub Release assets and the `install.sh` / `install.ps1` scripts.
- **Go tokenizer** — the release CI does not build one. `mix.exs` copies a *pre-built* `priv/go/tokenizer/osa-tokenizer` binary into the release only if it is already present; when absent, OSA falls back to a heuristic token count at runtime.
- **Docker image publishing** — the `Dockerfile` is provided for self-hosting but no image is pushed to a registry as part of the release pipeline.

## Local Release Verification

To verify a release locally before tagging:

```bash
# Assemble the OTP release
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix release osagent --overwrite

# Test the binary
./_build/prod/rel/osagent/bin/osagent version
# Expected: osagent v1.0.3

# Build the Rust TUI
cd priv/rust/tui && cargo build --release && cd -
```
