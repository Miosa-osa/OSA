# Change Management

## Overview

This document describes how changes to OSA are versioned, released, and
communicated. The process is designed to keep contributors aligned and to
protect users from unexpected breaking changes.

---

## Versioning

OSA uses Semantic Versioning (`MAJOR.MINOR.PATCH`).

The canonical version is stored in `/VERSION` at the project root. This file
is the single source of truth. `mix.exs` reads it at compile time:

```elixir
@version "VERSION" |> File.read!() |> String.trim()
```

No other file should hard-code the version number. Configuration, release
manifests, and API responses that expose the version must read from the
`VERSION` file or from `Application.spec(:optimal_system_agent, :vsn)` at
runtime.

Current version: **1.0.002**

### Pre-1.0 Policy

While the major version is 0, the following relaxed policy applies:

- **MINOR version**: May contain breaking changes. Breaking changes in a
  pre-1.0 minor release require an ADR.
- **PATCH version**: Bug fixes only. No new public API surface. No behavioral
  changes that affect existing functionality.

This policy exists because the public API of OSA (environment variables, HTTP
endpoints, hook signatures, tool behaviour callbacks) is still being stabilized.
Contributors should not assume backward compatibility between 0.x.y releases.

### Post-1.0 Policy

Once version 1.0.0 is released:

- **MAJOR**: Breaking changes to public API surface
- **MINOR**: Backward-compatible new features
- **PATCH**: Backward-compatible bug fixes

---

## Release Process

### Build

OSA ships as a compiled Mix release (`mix release`). The release binary is
named `osagent`. Release configuration lives in `rel/`.

```bash
mix deps.get
mix compile
MIX_ENV=prod mix release osagent
```

The release bundles the BEAM runtime and all compiled bytecode. Users run
`_build/prod/rel/osagent/bin/osagent start` without requiring an Elixir
installation on the target machine.

### Steps for a Release

1. Update `VERSION` to the new version string
2. Update `docs/operations/changelog.md` with the changes since last release
3. Verify all tests pass: `mix test`
4. Build the release: `MIX_ENV=prod mix release osagent`
5. Tag the commit: `git tag v<VERSION>`
6. Push the tag: `git push origin v<VERSION>`
7. Publish the GitHub release with the changelog section as release notes

### Release Artifacts

| Artifact | Description |
|---|---|
| `osagent` binary | Self-contained release, distributed via GitHub Releases |
| Docker image | Built from `Dockerfile`, published to container registry |
| Homebrew formula | `Formula/osagent.rb`, updated for each release |
| Install script | `install.sh`, version-pinned on each release |

---

## Changelog

Changes are documented in `docs/operations/changelog.md` in
[Keep a Changelog](https://keepachangelog.com/) format.

### Categories

| Category | Contents |
|---|---|
| `Added` | New features, new environment variables, new endpoints |
| `Changed` | Behavioral changes to existing features |
| `Deprecated` | Features to be removed in a future release |
| `Removed` | Features removed in this release |
| `Fixed` | Bug fixes |
| `Security` | Security vulnerability fixes |

### Breaking Change Notices

Breaking changes are called out prominently at the top of the relevant version
section with a `> BREAKING:` blockquote. Example:

```markdown
## [0.3.0] - 2025-06-01

> BREAKING: The `OSA_PROVIDER` environment variable is replaced by
> `OSA_LLM_PROVIDER`. Update your environment before upgrading.

### Added
...
```

---

## Requirements for New Features

New features merged to the main branch must include:

1. **Tests**: Unit tests for logic, integration tests for API-visible behavior.
   Coverage targets are 80% statements, 75% branches. See `docs/development/`.
2. **Documentation**: Public-facing changes must update the relevant docs file.
   Internal changes require inline module documentation (`@moduledoc`).
3. **Changelog entry**: Add an entry to `docs/operations/changelog.md` under
   `[Unreleased]`.
4. **ADR (for significant changes)**: Changes to supervision tree structure,
   event routing, shim layer, or external API require an ADR in
   `docs/foundation-core/governance/architectural-decisions/`.

---

## Feature Flags

Optional features are controlled by environment variables, not compile-time
flags. Features that depend on external services, add significant overhead,
or are not yet stable are placed behind environment variable checks in the
`Supervisors.Extensions` init function.

### Convention

```elixir
# In supervisors/extensions.ex
defp fleet_children do
  if Application.get_env(:optimal_system_agent, :fleet_enabled, false) do
    [OptimalSystemAgent.Fleet.Supervisor]
  else
    []
  end
end
```

The corresponding environment variable follows the pattern `OSA_<FEATURE>_ENABLED=true`.

Features behind flags:

| Environment Variable | Feature |
|---|---|
| `OSA_FLEET_ENABLED` | Fleet management |
| `OSA_TREASURY_ENABLED` | Budget treasury |
| `OSA_SANDBOX_ENABLED` | Code sandbox |
| `OSA_WALLET_ENABLED` | Wallet integration |
| `OSA_UPDATE_ENABLED` | OTA updater |
| `OSA_GO_TOKENIZER_ENABLED` | Go tokenizer sidecar |
| `OSA_GO_GIT_ENABLED` | Go git sidecar |
| `OSA_GO_SYSMON_ENABLED` | Go sysmon sidecar |
| `OSA_PYTHON_SIDECAR_ENABLED` | Python sidecar |
| `OSA_WHATSAPP_WEB_ENABLED` | WhatsApp Web sidecar |
| `DATABASE_URL` | Platform PostgreSQL (presence enables) |
| `AMQP_URL` | AMQP publisher (presence enables) |

---

## Rollback

Rollbacks are performed by reverting to the previous release binary:

```bash
# Stop the current release
_build/prod/rel/osagent/bin/osagent stop

# Replace the binary with the previous release
# (from GitHub Releases or a stored artifact)

# Start the previous release
_build/prod/rel/osagent/bin/osagent start
```

SQLite WAL mode ensures the database is consistent after a binary rollback.
If a migration was run by the new version and the previous version does not
support the new schema, the migration must be manually reversed before rollback.
Migration rollback scripts are included in `priv/repo/migrations/` where applicable.
