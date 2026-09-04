# Codex context budgets

OSA defaults to the model-specific maximum advertised by the Codex client
catalog. That value is not proof of the service's hard limit or account
entitlement. Public API model windows and Codex client budgets are distinct.

For an explicitly configured larger client budget, add exact model IDs to
`settings.json` in the active OSA config directory:

```json
{
  "codex_context_windows": {
    "gpt-6-astra": 1000000
  }
}
```

This changes the shared window resolver used by prompt construction, context
reporting, and compaction. It does not add an unsupported request parameter,
change authentication, or grant more server-side context. A provider can still
reject an oversized request. Large requests may increase cost or subscription
usage. Do not interpret a configured meter value as a successful capacity test.

Overrides are exact-model, Codex-provider-only positive integer values.
Invalid values fall back to the catalog. Values cannot exceed the published
model window where known, or the Codex catalog value otherwise. Small models
do not inherit a flagship's setting. Restart the backend after configuration
changes so active sessions consistently reload their budget.
