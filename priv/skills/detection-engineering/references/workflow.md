# Worked workflow

Original rule for a custom application JSON log (field mapping required):
```yaml
title: OSA Lab SQL Injection Signal
id: f5ad06e0-c2c6-4ec4-8aa7-0b3ff4ef3210
status: experimental
description: Alerts on an explicit lab detector signal, not arbitrary query text.
author: OSA
date: 2026-09-14
logsource:
  category: application
  product: osa_lab
detection:
  selection:
    event_type: injection_attempt
  condition: selection
falsepositives:
  - Authorized lab tests
level: medium
```
Positive fixture: `{"event_type":"injection_attempt"}`. Benign: `{"event_type":"query_ok"}`. Missing field: `{}`. Expected matches: 1, 0, 0, respectively; reject malformed JSON separately. These are custom rule fixtures, not a promise of the runner's event schema.
Optional backend conversion requires `command -v sigma`, `sigma --help`, and the locally installed target and processing pipeline. Save generated query, backend version, ingestion evidence and actual alert results. No backend configured means integration unverified.
For lab-only comparison use `cyber_defense` with `{"action":"run","scenario":"sql_injection","remediation":"apply"}`.

## Primary references

- [Sigma rule specification](https://sigmahq.io/sigma-specification/specification/sigma-rules-specification.html)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
