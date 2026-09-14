# Worked workflow

Hypothesis: a new service provides unexpected persistence. Read-only Linux collection:
```sh
systemctl list-unit-files --state=enabled --no-pager
systemctl list-timers --all --no-pager
journalctl --since '24 hours ago' -o json --no-pager
```
Compare with an approved prior export and package/deployment records. A newly enabled backup service during maintenance is the benign control. An unknown enabled service invoking a user-writable executable warrants investigation, not automatic deletion.
Record service path, owner, hash, install time evidence, execution evidence and authorization status. Missing historical service inventory makes the creation time unknown. Do not infer no persistence from these three commands: user units, scheduled jobs and other mechanisms need separate coverage.

## Primary references

- [MITRE adversary emulation](https://attack.mitre.org/resources/adversary-emulation-plans/)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
