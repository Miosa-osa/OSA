# Worked workflow

Example flow: an authenticated user supplies a download filename to a service that reads storage. Trust boundary: user-controlled name to service filesystem access.
Abuse case: traversal escapes the intended directory. Control: canonical containment plus authorization for the resolved object. Check normal downloads, rejected traversal and tenant isolation in the real implementation.
For a bounded teaching demonstration invoke `cyber_defense` with `{"action":"run","scenario":"path_traversal","remediation":"apply"}`. Record its limitation: it proves the fixture's behavior only.
Deliver a record per threat: `asset, flow, boundary, preconditions, consequence, evidence, control, test, owner, residual_risk`. Avoid asserting immunity merely because a checklist or diagram is complete.

## Primary references

- [OWASP threat modeling](https://cheatsheetseries.owasp.org/cheatsheets/Threat_Modeling_Cheat_Sheet.html)

Original OSA examples; no third-party rules or source text copied. Consult the linked publisher terms before redistributing upstream material.
