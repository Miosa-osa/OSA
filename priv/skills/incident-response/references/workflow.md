# Worked workflow

On an authorized Linux host, use `shell_execute` for read-only observations and save output through `file_write` in the case directory:
```sh
ps -eo pid,ppid,user,lstart,args
ss -tulpn
journalctl --since '2026-09-14 00:00:00 UTC' --until '2026-09-14 01:00:00 UTC' -o json --no-pager
```
Process arguments and logs can contain secrets; keep originals access-restricted and produce a redacted report copy. Record insufficient privileges as incomplete acquisition.
After saving exports, `sha256sum case/events.jsonl` records file integrity, not source authenticity. Never claim this acquires memory or disk images.
Example: login failure bursts followed by one success are suspicious only after checking source, user history and maintenance activity. Record alternative explanations and validate containment with a fresh login from the permitted recovery path.

## Primary references

- [NIST SP 800-61 Rev. 3](https://csrc.nist.gov/pubs/sp/800/61/r3/final)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
