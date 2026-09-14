# Worked workflow

Create a harmless JSONL canary through `file_write`:
```json
{"event_type":"osa_defense_canary","event_id":"lab-run-001","timestamp":"2026-09-14T00:00:00Z","severity":"test"}
```
Use the user's documented collector input in a test index; no SIEM connector is bundled by this skill. Change timestamp and unique event ID for every run. Capture producer receipt, indexed document ID, query result, alert ID and delivery receipt. Send a second event with `event_type: ordinary_activity` as the benign control.
Use `log-analysis` to count exported JSONL, but do not equate export counts with end-to-end delivery. For clock skew, retain both source and ingestion timestamps. Missing access to the alert destination means delivery remains unverified.

## Primary references

- [Sigma rule specification](https://sigmahq.io/sigma-specification/specification/sigma-rules-specification.html)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
