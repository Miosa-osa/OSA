# UX-003: Ollama Not Selectable in Desktop Provider Dropdown

> **Severity:** UX
> **Status:** Open
> **Component:** `desktop/src/routes/app/models/+page.svelte`, `desktop/src/lib/stores/models.svelte.ts`
> **Reported:** 2026-03-14

---

## Summary

The desktop Models page (`/app/models`) fetches models via `GET /api/v1/models`
and groups them by provider. Ollama models are returned by the backend as
`{is_local: true, provider: "ollama"}`. However, the `modelsStore.activateModel`
function calls `POST /api/v1/models/<name>/activate`, which is not a route that
exists in `data_routes.ex`. The backend has `POST /models/switch` (body:
`{provider, model}`) as the correct endpoint, but the client uses the wrong path.

## Symptom

User navigates to Models, sees Ollama models listed, clicks one to activate it.
The request fails silently (the store catches the `ApiError` but shows no
toast/banner). The active model indicator does not update.

## Root Cause

`client.ts` line 303 defines:

```typescript
activate: (name: string) =>
  request<Model>(`/models/${encodeURIComponent(name)}/activate`, {
    method: "POST",
  }),
```

The backend (`data_routes.ex`) has no `POST /models/:name/activate` route.
The correct endpoint is `POST /models/switch` with a JSON body:
```json
{"provider": "ollama", "model": "llama3.2:latest"}
```

The store's `activateModel` function calls `models.activate(name)` without
providing the provider name, and uses the wrong HTTP path.

Additionally, Ollama models returned by the backend do not include a `provider`
field in a consistent format — `is_local: true` is set, but the provider slug
needed for the `/models/switch` body is not always `"ollama"`. Some Ollama
Cloud models have a different URL prefix.

## Impact

- Users cannot switch models from the desktop UI when using Ollama.
- The active model display is stuck on whichever model was active at application
  boot.
- All local-first Ollama users are affected.

## Suggested Fix

Update `client.ts` to use the correct endpoint:

```typescript
activate: (name: string, provider: string) =>
  request<{ provider: string; model: string; status: string }>(
    "/models/switch",
    {
      method: "POST",
      body: JSON.stringify({ provider, model: name }),
    },
  ),
```

Update `modelsStore.activateModel` to pass the provider slug derived from the
model's `provider` field.

## Workaround

Use the CLI command `/model ollama llama3.2:latest` or make a direct API call:
```bash
curl -X POST http://localhost:9089/api/v1/models/switch \
  -H "Content-Type: application/json" \
  -d '{"provider": "ollama", "model": "llama3.2:latest"}'
```
