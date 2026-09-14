# OSA 1.0.200 completion scope

This change follows the operator's original OSA session and subsequent handoff.
The target version remains 1.0.200. The requested deliverable is a reviewable PR;
publishing, merging, tagging and deployment are paused.

## Requests carried forward

1. Local model setup: retain installed Mythos variants for manual use. Earlier
   setup/benchmark numbers are historical session claims, not measurements from
   this change. Do not delete old model weights without a selection from the
   operator. Work on this change uses cloud agents; no local-model delegation.
2. Elixir/Erlang skill: bundle corrected portable guidance and executable examples.
3. Red-team/OSINT library: preserve the previously merged library and complete
   the eight reference splits which had not reached the shipped tree.
4. Security repairs and tools: verify real semantics, strengthen the pipeline
   tests, and repair deterministic failures in the merged baseline.
5. CLI arsenal: repair/finish the local installations and distinguish executable
   checks from proof of external-service integration.
6. Cyber defense: ship the twelve requested skill domains plus executable tools
   for isolated target simulation, detection checks, lab remediation, and retest.

## Runnable defense workflow

Discover `cyber_defense` with `tool_search`, then list `scenarios`. Execute:

```json
{"action":"run","scenario":"all","remediation":"apply","timeout_seconds":30}
```

The tool executes bundled SQL injection, path traversal and authentication
rate-limit examples inside a disposable Docker container. It observes the
vulnerable baseline, applies a lab control, repeats the exercise, checks benign
requests, and returns JSON evidence with a hash and cleanup result. Repeat with
`remediation: none` or `ineffective` to test negative controls; both must remain
unverified. These are synthetic application targets, not arbitrary targets,
production patches, a malware-detonation VM, or proof of SIEM coverage.

The twelve skills cover attack simulation, detection engineering, incident
response, threat hunting, log analysis, network defense, email security,
endpoint hardening, vulnerability management, sandbox triage, SIEM operations,
and threat modeling. Bounded JSONL and static EML helpers are included.
External Sigma backends, YARA, Suricata, SIEM accounts, and malware-analysis VMs
are separately configured prerequisites. The source register states exactly
what was researched and what remains outside the executable lab.

## Review evidence

- `completion-audit.md`: recovered original work and local arsenal checks.
- `defense-sources.md`: primary sources, reuse boundaries and external prerequisites.
- `test/security/defense_lab_integration_test.exs`: actual Docker execution.
- `test/tools/cyber_defense_discovery_test.exs`: native-tool discovery and skill use.
- `test/security_intel_pipeline_eval_test.exs`: evidence, severity, dedup and SARIF.
- `.github/workflows/ci.yml`: full suites plus actual lab and helper gates.

No host remediation or external target engagement is performed by the lab.
