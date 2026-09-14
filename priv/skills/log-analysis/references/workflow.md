# Worked workflow

The command below assumes the repository root. For an installed skill, resolve `scripts/` relative to this skill directory and pass that absolute script path; do not assume the current working directory.

Use the bundled standard-library helper with `shell_execute`:
```sh
python3 priv/skills/log-analysis/scripts/summarize_jsonl.py case/events.jsonl
```
Input fixture:
```json
{"event_type":"login_failure","timestamp":"2026-09-14T00:00:00Z"}
{"event_type":"login_success","timestamp":"2026-09-14T00:01:00Z"}
```
Expected: 2 valid records, one count for each event type, no malformed lines. Adding a broken JSON line increases malformed count and returns exit 2; an empty file is zero observations, not a clean security finding. The helper counts fields only; it does not silently invent time normalization or correlate identities.

## Primary references

- [Python JSON parser](https://docs.python.org/3/library/json.html)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
