# Worked workflow

Read-only checks:
```sh
ss -tulpn
```
Optional Suricata (not bundled or automatically installed):
```sh
command -v suricata
suricata -T -c lab/suricata.yaml
suricata -r lab/fixture.pcap -c lab/suricata.yaml -l lab/output
```
Create `lab/output` first; use an approved offline capture and config with EVE output enabled. Preserve `eve.json`, stats and exit codes. An HTTP lab alert in the suspicious capture is a positive control; equivalent harmless requests should not trigger that signature. Encrypted payloads, dropped packets and missing interfaces are visibility limits.
For application abuse containment independently run `cyber_defense` with `{"action":"run","scenario":"auth_rate_limit","remediation":"apply"}`; this is not firewall or IDS validation.

## Primary references

- [Suricata command line](https://docs.suricata.io/en/latest/command-line-options.html)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
