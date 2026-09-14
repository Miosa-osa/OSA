# Worked workflow

Linux systemd read-only assessment (version-dependent):
```sh
systemctl cat example.service
systemctl show example.service -p User -p Group -p NoNewPrivileges -p ProtectSystem -p PrivateTmp
systemd-analyze security example.service
```
Replace `example.service` with an identified service; missing unit or unsupported property is not a passing check. A candidate change such as `NoNewPrivileges=yes` belongs in a reviewed drop-in. Record the exact prior drop-in and restoration/reload/restart commands before applying it.
Positive control: the service's normal health check continues to succeed. Negative control: an operation the new sandbox should forbid fails for the expected reason. Do not enable all hardening flags blindly: filesystem writes, device access and privilege transitions may be required.

## Primary references

- [systemd service security assessment](https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
