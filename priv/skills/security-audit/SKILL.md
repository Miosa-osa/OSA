---
name: security-audit
description: Review code, configuration, permissions, authentication, data handling, and dependencies for exploitable security weaknesses. Use for security reviews, threat analysis, trust boundaries, secrets, authorization, sandboxing, and dangerous command handling.
tools:
  - file_read
  - file_grep
  - file_glob
  - shell_execute
triggers:
  - security audit
  - vulnerability
  - threat model
  - authentication
  - authorization
---

# Security Audit

Report concrete attack paths and evidence, not generic checklists.

## Procedure

1. Establish assets, actors, entry points, trust boundaries, and deployment assumptions.
2. Trace untrusted input from ingress to sensitive sinks.
3. Review authentication, authorization, tenancy, and ownership separately.
4. Inspect secret storage, logging, serialization, file paths, commands, and network destinations.
5. Check fail-open behavior, race conditions, replay, confused-deputy paths, and privilege escalation.
6. Validate dependency findings against the versions actually resolved by the project.
7. Rank findings by exploitability and impact.
8. For each finding, provide evidence, an attack scenario, and a specific remediation.
9. Distinguish confirmed vulnerabilities from defense-in-depth recommendations.

## Safety

- Do not run destructive exploitation against real data or external systems.
- Use local fixtures or isolated environments for proof of concept.
- Never expose secrets in logs or reports.
- Do not claim a vulnerability from a pattern match without tracing reachability.

## Report

Order findings by severity.
Include file and line references, affected assumptions, and verification steps for the remediation.
