---
globs: ["**/*"]
description: "How to approach security audits. EDIT THIS FILE to add your insights."
---

# Security Audit Behavior Guide

**HUMAN EDIT SECTION** - Add your security insights below the line.

## Default Security Audit Protocol

### OWASP Top 10 Checklist

#### A01: Broken Access Control
- [ ] Authorization on all endpoints
- [ ] No IDOR vulnerabilities
- [ ] Rate limiting present
- [ ] CORS properly configured

#### A02: Cryptographic Failures
- [ ] TLS everywhere
- [ ] Strong encryption algorithms
- [ ] No hardcoded secrets
- [ ] Proper key management

#### A03: Injection
- [ ] Parameterized queries (SQL)
- [ ] Input sanitization
- [ ] Command injection prevention
- [ ] LDAP injection prevention

#### A04: Insecure Design
- [ ] Threat modeling done
- [ ] Security requirements defined
- [ ] Fail securely

#### A05: Security Misconfiguration
- [ ] Secure defaults
- [ ] Error handling (no stack traces)
- [ ] Security headers present
- [ ] Unnecessary features disabled

#### A06: Vulnerable Components
- [ ] Dependencies up to date
- [ ] No known vulnerabilities
- [ ] License compliance

#### A07: Authentication Failures
- [ ] Strong password policy
- [ ] MFA available
- [ ] Session management secure
- [ ] Brute force protection

#### A08: Data Integrity Failures
- [ ] Signed data where needed
- [ ] CI/CD pipeline secure
- [ ] Update verification

#### A09: Logging Failures
- [ ] Security events logged
- [ ] No sensitive data in logs
- [ ] Log injection prevention
- [ ] Monitoring/alerting

#### A10: SSRF
- [ ] URL validation
- [ ] Network segmentation
- [ ] Allowlisting external calls

## Security Headers
```
Strict-Transport-Security: max-age=31536000; includeSubDomains
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Content-Security-Policy: default-src 'self'
X-XSS-Protection: 1; mode=block
```

---

## YOUR INSIGHTS (Edit Below)

<!--
Add your own security insights here. Examples:

### Our Security Requirements
- All APIs require JWT authentication
- PII must be encrypted at rest
- Audit logging required for data access

### Known Vulnerabilities in Our Stack
- [Library X] has issue Y - mitigated by Z
- Legacy endpoint /api/v1/users needs auth added

### Compliance Requirements
- GDPR: User data deletion within 30 days
- SOC2: All access logged
- PCI: No card data stored

### Security Contacts
- Security team: security@company.com
- Incident response: oncall-security
-->

### Our Security Requirements
<!-- Add your security requirements -->

### Known Vulnerabilities to Watch
<!-- Add known issues -->

### Compliance Requirements
<!-- Add compliance needs -->

### Security Contacts
<!-- Who to contact for security issues -->

### Incident Response
<!-- What to do if breach detected -->
