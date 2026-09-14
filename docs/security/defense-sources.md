# Cyber-defense source and capability register

Research date: 2026-09-14. The 12 skills and examples are original OSA material, not ports of the unverified skill repositories in the earlier session shortlist. No upstream skill packs, offensive tools, malware, signatures or third-party code are vendored. Names and command interfaces are referenced for interoperability. An upstream project's code license must not be assumed to cover its documentation or rule collection.

## Primary sources reviewed

- [NIST SP 800-61 Rev. 3](https://csrc.nist.gov/pubs/sp/800/61/r3/final): incident response integrated with cybersecurity risk management; April 2025 final publication. Used to organize preparation, response and recovery. Referenced, no text copied; no blanket license claim for third-party material within publications.
- [MITRE adversary emulation plans](https://attack.mitre.org/resources/adversary-emulation-plans/): behavior-focused testing and mappings. Referenced conceptually, no plan or ATT&CK dataset redistributed. The implementation demonstrates three fixed application weaknesses, not a complete ATT&CK emulation campaign.
- [Sigma specification](https://sigmahq.io/sigma-specification/specification/sigma-rules-specification.html): structured logsource/detection/condition fields. The bundled example rule is original and targets a documented custom fixture schema. No community rules are copied; conversion requires separately installed backends and pipelines. No license conclusion about Sigma rule packs is inferred from the specification.
- [OWASP threat modeling cheat sheet](https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html): system boundaries, threat identification, mitigation and validation. Site identifies CC BY-SA 4.0; reference only, no text or diagram adapted into this change.
- [YARA command line](https://yara.readthedocs.io/en/stable/commandline.html): source-rule invocation, scan timeout, recursive scanning and the security distinction for compiled rules. Example marker rule is original. No YARA code or rule pack bundled.
- [Suricata command line](https://docs.suricata.io/en/latest/command-line-options.html): `-T` config test and `-r` offline PCAP input. Documentation currently resolves to a development-version manual; check installed `--help` and version before use. No Suricata code or rules bundled.
- [RFC 8601](https://www.rfc-editor.org/info/rfc8601/): Authentication-Results and receiver trust boundaries. IETF Trust/BCP 78 terms are linked by the RFC; reference only, no RFC text or code component copied.
- [Python email parser](https://docs.python.org/3/library/email.parser.html) and [JSON parser](https://docs.python.org/3/library/json.html): standard-library interfaces for the two bounded helpers. Documentation identifies PSF License v2 and 0BSD for examples; helpers here are original implementations, not copied recipes.

## Sources with retrieval limits

- [CISA KEV catalog](https://www.cisa.gov/known-exploited-vulnerabilities-catalog): direct browser retrieval returned HTTP 403 during this pass. Do not claim a current KEV membership from these docs. The skill matches an operator-provided dated JSON export, then requires vendor-version confirmation. No catalog data bundled and no bulk-feed reuse license inferred.
- [systemd-analyze manual](https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html) and [journalctl manual](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html): publisher pages blocked this browser. Verify commands against the target's installed manual/help. These read-only command examples are original; no upstream manual text bundled.

## Capabilities and prerequisites

The registered `cyber_defense` tool provides an atomic baseline → simulation → remediation → retest loop for `sql_injection`, `path_traversal`, and `auth_rate_limit`. It uses fixed Python demonstrations in disposable Docker containers, no network, no host mounts, non-root execution and a read-only root filesystem. It requires Docker and a preinstalled `python:3.12-slim` image. It is not a VM malware detonation service, real-target scanner, or SIEM connector. `none` and `ineffective` remediations provide negative controls. Results must not claim a real deployment was patched.

The skill library supplies concrete workflows and local helpers across 12 domains. External YARA, Suricata, Sigma backends and SIEM integrations remain optional prerequisites, not built-in or presumed configured capabilities. `command -v` in the development host found Python, jq, journalctl, sha256sum and Docker; YARA, Suricata and Sigma were absent. Recheck every target; these observations are not installation guarantees.

Two original helpers are shipped: bounded JSONL event counts with malformed-line reporting, and bounded static EML header extraction preserving duplicate fields. Neither performs network calls, authentication verification, malware execution or implicit event correlation. Read sensitive evidence only within the authorized case; derived reports need deliberate redaction.

## Validation scope

Each skill includes two eval prompts under `evals/evals.json`; these are review inputs, not claims of completed model evaluations. Deterministic helper unit tests and OSA authoring/discovery tests establish narrower executable properties. Actual external SIEM alert delivery, YARA/Suricata rule execution and malware VM detonation are not validated by the built-in lab results.
