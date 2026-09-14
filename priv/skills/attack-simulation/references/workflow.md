# Worked workflow

Invoke the registered OSA tool, not a shell command:
```json
{"action":"run","scenario":"all","remediation":"apply","timeout_seconds":30}
```
Tool: `cyber_defense`. Supported scenario names: `sql_injection`, `path_traversal`, `auth_rate_limit`, `all`.
Negative control:
```json
{"action":"run","scenario":"sql_injection","remediation":"ineffective","timeout_seconds":30}
```
Expected: baseline attack succeeds on the intentionally vulnerable fixture; the effective fix blocks it while benign use succeeds. An ineffective fix retains attack success and cannot verify remediation. Inspect actual results instead of supplying these expectations as measurements.
The runner uses fixed embedded programs with no network, host mounts or arbitrary code. It does not run unknown malware or full adversary campaigns. Disposable target removal is lab rollback; production rollback needs an independently prepared patch/revert plan.

## Primary references

- [MITRE adversary emulation](https://attack.mitre.org/resources/adversary-emulation-plans/)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
