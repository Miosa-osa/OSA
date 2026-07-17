# Deprecation Process

This document describes how features, configuration keys, API endpoints, and
behaviours are deprecated and removed in OSA.

---

## Deprecation Lifecycle

A deprecation moves through three stages:

```
Announced → Deprecated (1+ releases) → Removed
```

1. **Announced**: The deprecation is noted in a changelog entry and (where
   possible) a runtime warning is added.
2. **Deprecated**: The feature still works. A deprecation warning appears in
   logs at startup or on first use. The deprecation is documented.
3. **Removed**: The feature is gone. The removal is a MINOR version bump at
   v0.x (would be a MAJOR bump at v1.x). A migration guide is provided.

---

## Deprecation Warning Conventions

### Startup warnings

Configuration key renames and removed options log at startup via `Logger.warning`:

```elixir
# Example: renaming OSA_PROVIDER to OSA_DEFAULT_PROVIDER
if Application.get_env(:optimal_system_agent, :provider) do
  Logger.warning(
    "[DEPRECATED] The :provider config key is deprecated. " <>
    "Use :default_provider instead. Support will be removed in a future release."
  )
end
```

Startup warnings appear before the supervision tree is fully initialized so they
are visible in all log outputs.

### First-use warnings

Functions that are deprecated but not yet removed emit a warning on first call:

```elixir
@deprecated "Use Providers.Registry.chat/2 with provider: option instead"
def chat_with_provider(provider, messages, opts \\ []) do
  Logger.warning("[DEPRECATED] chat_with_provider/3 is deprecated. Use chat/2 with provider: option.")
  chat(messages, Keyword.put(opts, :provider, provider))
end
```

The `@deprecated` attribute causes the Elixir compiler to emit a deprecation
notice when the function is called from other modules at compile time.

### Module-level deprecation

When an entire module is deprecated:

```elixir
defmodule OptimalSystemAgent.OldModule do
  @moduledoc """
  DEPRECATED: Use `OptimalSystemAgent.NewModule` instead.
  This module will be removed in a future release.
  """
  ...
end
```

---

## Timeline Expectations

At v0.x, the minimum deprecation window is **one MINOR release**. That means:

- A feature deprecated in 0.2.x must survive through the entirety of 0.2.x.
- It may be removed in 0.3.0.

No deprecation window applies to:
- Features that are security vulnerabilities
- Features that are stubs returning `:not_implemented` (these are not considered
  part of the public API)
- Features documented only in `@doc false` or without any changelog entry

At v1.x (when reached), the minimum deprecation window increases to **one MAJOR
release** — a feature deprecated in 1.x cannot be removed until 2.0.

---

## What Gets Deprecated

### Environment variables and configuration keys

When a configuration key is renamed, the old key is read and mapped to the new key
for at least one MINOR release with a startup warning. Example:

```
Old: OSA_PROVIDER=anthropic
New: OSA_DEFAULT_PROVIDER=anthropic
Transition: Both read, old key mapped to new, startup warning logged.
```

### Public functions with `@doc` annotation

Functions documented with `@doc` are part of the public API. They are deprecated
with `@deprecated` and the deprecation is noted in the changelog. The deprecated
function delegates to the replacement for at least one MINOR release.

### HTTP API endpoints

Deprecated endpoints continue to respond but include a `Deprecation` HTTP header:

```
Deprecation: true
Sunset: 2025-06-01
Link: </api/v1/new-endpoint>; rel="successor-version"
```

The endpoint is removed after the sunset date, which must be at least one MINOR
release after the deprecation was announced.

### Hook event names

Hook lifecycle events (`:pre_tool_use`, `:post_tool_use`, etc.) are not renamed
lightly. When a rename is necessary, both the old and new names are dispatched
through `Agent.Hooks` for one MINOR release. Handlers registered under the old
name continue to work with a log warning on each invocation.

### Behaviour callbacks

Adding new required callbacks to a behaviour is a breaking change. The process:

1. Add the new callback as optional with a default implementation in the behaviour.
2. Announce in the changelog that it will become required in the next MINOR release.
3. Make it required in the next MINOR release and update all callers.

Removing a callback from a behaviour uses the standard deprecation process: keep
the callback for one MINOR release with a `@deprecated` annotation, then remove it.

---

## Currently Deprecated Items

As of v1.0.002, no public API features are in the deprecated-but-not-removed state.

Items in the shim layer (`lib/miosa/shims.ex`) that delegate to the real
implementations are not deprecated — they are the designed access path for
`Miosa*` namespace callers and will remain until the packages are extracted.
The stub implementations in the shim layer (`MiosaKnowledge.*`) are explicitly
marked `:not_implemented` and are not considered part of the stable API.

---

## Communicating Deprecations

Every deprecation is communicated in three places:

1. **Changelog**: Entry in `docs/operations/changelog.md` under `Deprecated`.
2. **Runtime log**: Startup or first-use warning via `Logger.warning`.
3. **Code**: `@deprecated` attribute or `@moduledoc` notice.

For deprecations affecting external integrations (HTTP API consumers, SDK users),
a GitHub Discussion thread is opened to gather feedback before the removal proceeds.
