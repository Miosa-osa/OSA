# UX-005: Desktop Client / Backend Port Mismatch

> **Severity:** UX
> **Status:** Resolved — the backend default is now `9089`, matching the desktop client
> **Component:** `desktop/src/lib/api/client.ts`, `lib/mix/tasks/osa.serve.ex`
> **Reported:** 2026-03-14

---

## Resolution

Both sides now default to port `9089`, so the mismatch no longer exists:

- `config/config.exs` — `http_port: 9089`
- `lib/mix/tasks/osa.serve.ex` — `Application.get_env(:optimal_system_agent, :http_port, 9089)`
- `desktop/src/lib/api/client.ts` — `BASE_URL = "http://127.0.0.1:9089"`

The historical analysis below is preserved for reference; it described an
earlier state where the backend defaulted to `8089`.

## Summary (historical)

The desktop Tauri application hard-codes the backend URL as
`http://127.0.0.1:9089` in `client.ts` line 24:

```typescript
export const BASE_URL = "http://127.0.0.1:9089";
```

At the time this was reported, the backend default port set in `mix osa.serve`
and `config.exs` was `8089`, so the two were out of sync on a fresh install.
The backend default has since been changed to `9089`.

## Symptom

Desktop app starts, health check to `http://127.0.0.1:9089/health` fails with
`ERR_CONNECTION_REFUSED`. The connection indicator shows red. All API calls fail.
The app is non-functional until the user manually starts the backend on port
9089 or reconfigures one side.

## Root Cause

Two independent defaults were set during development and were never reconciled:

- `desktop/src/lib/api/client.ts:24` — `BASE_URL = "http://127.0.0.1:9089"`
- `lib/mix/tasks/osa.serve.ex:27` — `http_port` defaults to `8089`
- `config/config.exs` — `http_port: 8089`

There is no runtime configuration mechanism in the desktop app to discover the
correct port. The `settingsStore.ts` has a `serverUrl` field but it is not
read by `client.ts`; `BASE_URL` is a module-level constant evaluated at import
time.

## Impact

- All users on a fresh install cannot use the desktop app without manual
  reconfiguration.
- The discrepancy is non-obvious; the error appears as a generic network failure
  with no hint that ports are mismatched.
- Documentation and README reference `8089` for curl examples but the desktop
  app expects `9089`.

## Suggested Fix

**Option A (applied):** Standardise on port `9089` in both places. This is the
current state — `config.exs`, `osa.serve.ex`, and `client.ts` all use `9089`.

**Option B:** Make `BASE_URL` dynamic by reading from the Tauri store or an
environment variable baked in at build time:
```typescript
export const BASE_URL =
  import.meta.env.VITE_BACKEND_URL ?? "http://127.0.0.1:8089";
```

**Option C:** Use the `serverUrl` from `settingsStore.ts` as the base URL,
allowing users to configure a non-default port in the Settings page.

## Workaround

No workaround needed on current versions — both sides default to `9089`. To run
the backend on a non-default port, set `OSA_HTTP_PORT` and point the desktop
client at the same value:
```bash
OSA_HTTP_PORT=9090 mix osa.serve
```
