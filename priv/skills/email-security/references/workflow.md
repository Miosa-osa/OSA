# Worked workflow

The command below assumes the repository root. For an installed skill, resolve `scripts/` relative to this skill directory and pass that absolute script path; do not assume the current working directory.

Run:
```sh
python3 priv/skills/email-security/scripts/headers.py case/message.eml
```
The helper prints selected headers as JSON and never fetches URLs, renders HTML or executes attachments. It does not validate DKIM cryptography or DMARC policy.
Example: two Authentication-Results fields disagree. Attribute each to its authserv-id and the trusted receiver boundary; do not accept an external `dmarc=pass` claim as authoritative. A benign internal message with a trusted pass is a control, not a reason to suppress all internal mail. Preserve the raw sample and use a mail-system test tenant to validate a proposed quarantine rule before production rollout.

## Primary references

- [RFC 8601 authentication results](https://www.rfc-editor.org/info/rfc8601/)
- [Python header parser](https://docs.python.org/3/library/email.parser.html)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
