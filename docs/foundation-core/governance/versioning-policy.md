# Versioning Policy

## Overview

OSA uses Semantic Versioning 2.0.0 (`MAJOR.MINOR.PATCH`). The version is
stored in a single file at the project root and read by the build system,
release tooling, and runtime introspection.

---

## Version File

The canonical version is `/VERSION`:

```
1.0.002
```

No trailing newline. No `v` prefix. This file is read by `mix.exs`:

```elixir
@version "VERSION" |> File.read!() |> String.trim()
```

And available at runtime:

```elixir
Application.spec(:optimal_system_agent, :vsn) |> to_string()
# => "1.0.002"
```

To bump the version, edit only the `VERSION` file. Do not edit `mix.exs`
or any other file. CI validates that the `VERSION` file is the sole source
of truth.

---

## Current Version: 1.0.002

OSA has shipped 1.0. The public API surface — environment variables, HTTP
endpoints, hook signatures, tool behaviour callbacks, channel protocols — is now
covered by the semantic-versioning guarantees below: breaking changes are
confined to major version bumps.

---

## Version Semantics

### Major Version (X.y.z)

Incremented when a backward-incompatible change is made to the public API
that cannot be handled by a migration guide alone. Examples:

- Removal of a core environment variable with no replacement
- Change to the HTTP API response format in a way that breaks existing clients
- Removal of a `MiosaTools.Behaviour` callback that all tool modules implement
- Change to the OTP release structure that requires manual migration

Major version 0 will remain until the public API is stable enough to guarantee
backward compatibility within a major version. The target for 1.0 is defined
by the completion of API stabilization as tracked in project issues.

### Minor Version (x.Y.z)

Incremented when new functionality is added in a backward-compatible manner,
OR (in pre-1.0) when a breaking change is made that is documented in an ADR.

Pre-1.0 breaking changes in a minor version must include:

- An ADR in `docs/foundation-core/governance/architectural-decisions/`
- A `> BREAKING:` notice at the top of the changelog entry
- A migration guide if the change requires user action

New minor versions must not introduce breaking changes to `PATCH` releases
(i.e., 0.2.7 must not break 0.2.6 behavior).

### Patch Version (x.y.Z)

Incremented for bug fixes only. A patch release:

- Fixes incorrect behavior against documented specification
- Does not add new public API surface
- Does not change startup behavior, supervision strategy, or extension policy
- Does not require user configuration changes

If a fix requires a configuration change or has any behavioral side effect
visible to users, it is a minor version bump, not a patch.

---

## Pre-Release and Build Metadata

OSA does not currently publish pre-release versions (`0.3.0-rc.1`) or use
build metadata (`0.3.0+20250601`). If pre-release versions are needed in the
future, they will follow SemVer 2.0.0 conventions with `-` separating the
pre-release identifier.

---

## Version Bump Checklist

Before tagging a new version:

- [ ] Update `/VERSION` to the new version string
- [ ] Verify `mix.exs` reads the new version correctly: `mix run -e "IO.puts Application.spec(:optimal_system_agent, :vsn)"`
- [ ] Add changelog entry to `docs/operations/changelog.md`
- [ ] For breaking changes: ADR written and merged
- [ ] All tests pass: `mix test`
- [ ] Release build succeeds: `MIX_ENV=prod mix release osagent`
- [ ] Git tag created: `git tag v1.0.010`

---

## Dependency Versioning

OSA pins all direct dependencies with version constraints in `mix.exs`. The
`mix.lock` file is committed to the repository and must be updated when
dependencies change.

Policy:

- Use `~>` (pessimistic) constraints: `{:req, "~> 0.5"}` allows 0.5.x but
  not 0.6.0
- `override: true` is used only for the goldrush fork dependency to prevent
  transitive version conflicts
- `mix.lock` updates require a separate commit or PR section clearly noting
  the dependency changes and their reason
