# CI/CD Pipeline

Audience: contributors who need to understand when and how release artifacts are built and published.

## Overview

OSA has two GitHub Actions workflows in `.github/workflows/`:

| Workflow | File | Trigger |
|---------|------|---------|
| Release | `release.yml` | Push of a `v*` tag |
| Update Homebrew Tap | `update-homebrew.yml` | GitHub release published |

There is no continuous integration workflow that runs on pull requests or pushes to `main`. Contributors must verify `mix test` and `mix format` locally before opening a PR.

## Release Workflow (`release.yml`)

### Trigger

Any push to a tag matching `v*`:

```bash
git tag v1.0.002
git push origin v1.0.002
```

### Environment Versions

```yaml
OTP_VERSION:    "27.2"
ELIXIR_VERSION: "1.17.3"
GO_VERSION:     "1.22"
MIX_ENV:        prod
```

### Jobs

#### `create-release`

Runs on `ubuntu-latest`. Creates the GitHub release object with auto-generated release notes. This job must complete before `build` jobs start.

#### `build` (matrix)

Builds release tarballs for four targets in parallel:

| Target | Runner | GOOS | GOARCH |
|--------|--------|------|--------|
| `darwin-arm64` | `macos-14` | `darwin` | `arm64` |
| `darwin-amd64` | `macos-14` | `darwin` | `amd64` |
| `linux-amd64` | `ubuntu-latest` | `linux` | `amd64` |
| `linux-arm64` | `ubuntu-latest` | `linux` | `arm64` |

Each build job runs these steps:

1. Checkout source at the tag.
2. Set up Erlang/OTP 27.2 and Elixir 1.17.3 via `erlef/setup-beam@v1`.
3. Set up Go 1.22 via `actions/setup-go@v5`.
4. Build the Go tokenizer: `CGO_ENABLED=0 go build -o osa-tokenizer .` with the target `GOOS`/`GOARCH` set.
5. Install Elixir production deps: `mix deps.get --only prod`.
6. Compile: `mix compile`.
7. Assemble release: `mix release osagent`.
8. Package tarball: `tar -czf osa-{platform}.tar.gz .` from `_build/prod/rel/osagent/`.
9. Upload tarball to the GitHub release via `gh release upload`.

Tarball naming convention: `osa-{platform}.tar.gz` (Windows ships `osa-windows-x64.zip`). Each asset has a `.sha256` sidecar. The version is not part of the filename — it lives in the release tag path.

Examples:
- `osa-macos-arm64.tar.gz`
- `osa-linux-x64.tar.gz`

### Artifact Storage

Tarballs are attached directly to the GitHub release. There is no separate artifact store or registry.

## Update Homebrew Tap Workflow (`update-homebrew.yml`)

### Trigger

When a GitHub release is published (fires after `release.yml` completes and the release is no longer a draft).

### Steps

1. Extract the version from the release tag.
2. Wait 30 seconds for release assets to become available.
3. Download all four tarballs and compute `sha256` checksums.
4. Checkout `Miosa-osa/homebrew-tap` using the `HOMEBREW_TAP_TOKEN` secret.
5. Render the Homebrew formulas `Formula/osa.rb`, `Formula/osagent.rb`, and `Formula/miosa.rb` with current version and checksums.
6. Commit and push to the tap repository.

Each formula installs the release tarball into `libexec/` and symlinks `osa`, `osagent`, and `miosa` to `libexec/bin/osagent`. The `test do` block asserts all three entrypoints print a version string.

### Required Secrets

| Secret | Purpose |
|--------|---------|
| `HOMEBREW_TAP_TOKEN` | GitHub PAT with write access to `Miosa-osa/homebrew-tap` |
| `GITHUB_TOKEN` | Automatically provided by Actions for reading release assets |

## Releasing a New Version

1. Update the `VERSION` file:
   ```bash
   echo "1.0.002" > VERSION
   git add VERSION
   git commit -m "[chore] Bump version to 1.0.002"
   ```
2. Push the commit to `main`.
3. Tag and push:
   ```bash
   git tag v1.0.002
   git push origin main
   git push origin v1.0.002
   ```
4. Watch the `Release` workflow at `github.com/Miosa-osa/OSA/actions`.
5. After the release is marked published, the Homebrew tap workflow runs automatically.

## What Is Not Automated

- **Test runs on PRs** — no CI job runs tests automatically. Contributors run `mix test` locally.
- **Linting** — `mix format` is not enforced by CI. Run it before committing.
- **Docker image publishing** — the `Dockerfile` is provided for self-hosting but no image is pushed to a registry as part of the release pipeline.
- **Windows builds** — the release matrix covers macOS and Linux only. Windows users run OSA under WSL2 or use the Elixir source directly.

## Local Release Verification

To verify a release locally before tagging:

```bash
# Build tokenizer
cd priv/go/tokenizer && CGO_ENABLED=0 go build -o osa-tokenizer . && cd ../../..

# Assemble release
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix release osagent

# Test the binary
./_build/prod/rel/osagent/bin/osagent version
# Expected: osagent v1.0.002
```
