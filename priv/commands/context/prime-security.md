---
name: prime-security
description: Load security audit and best practices context
---

# Prime: Security

## OWASP Top 10 Checklist
1. **Injection**: Parameterized queries, input validation
2. **Broken Auth**: Secure session management, MFA
3. **Sensitive Data**: Encryption at rest and transit
4. **XXE**: Disable external entities
5. **Broken Access**: Verify authorization on every request
6. **Misconfiguration**: Secure defaults, no verbose errors
7. **XSS**: Output encoding, CSP headers
8. **Insecure Deserialization**: Validate before deserializing
9. **Vulnerable Components**: Regular dependency updates
10. **Insufficient Logging**: Audit trails, alerting

## Code Review Security Checklist
- [ ] No secrets in code
- [ ] Input validation on all user data
- [ ] Output encoding for XSS prevention
- [ ] Parameterized database queries
- [ ] Proper authentication checks
- [ ] Authorization verified on each endpoint
- [ ] HTTPS only
- [ ] Secure headers (CSP, HSTS, etc.)
- [ ] Rate limiting on sensitive endpoints
- [ ] Audit logging for security events
