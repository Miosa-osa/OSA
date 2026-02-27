---
name: harden
description: Security hardening recommendations for the codebase
---

# Security Hardening Command

Generate security hardening recommendations based on codebase analysis.

## Usage
```
/harden [--target=<web|api|container|infrastructure|all>]
```

## Execution Workflow

### Step 1: Analyze Current Security Posture
```bash
# Check for existing security configurations
ls -la .env* 2>/dev/null
cat package.json | jq '.scripts | keys | map(select(contains("security") or contains("audit")))' 2>/dev/null
ls -la .github/workflows/*security* 2>/dev/null
```

### Step 2: Generate Recommendations by Target

#### Web Application Hardening
```yaml
security_headers:
  required:
    Strict-Transport-Security: "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options: "nosniff"
    X-Frame-Options: "DENY"
    Content-Security-Policy: "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'"
    X-XSS-Protection: "1; mode=block"
    Referrer-Policy: "strict-origin-when-cross-origin"
    Permissions-Policy: "geolocation=(), camera=(), microphone=()"

  implementation:
    express: |
      const helmet = require('helmet');
      app.use(helmet());
      app.use(helmet.contentSecurityPolicy({
        directives: {
          defaultSrc: ["'self'"],
          scriptSrc: ["'self'"],
          styleSrc: ["'self'", "'unsafe-inline'"],
        }
      }));

    nginx: |
      add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header X-Frame-Options "DENY" always;
      add_header Content-Security-Policy "default-src 'self'" always;

cookie_security:
  flags:
    - HttpOnly: true
    - Secure: true
    - SameSite: Strict
  implementation: |
    res.cookie('session', token, {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: 3600000
    });

input_validation:
  - Validate all user inputs server-side
  - Use allowlist validation over denylist
  - Sanitize outputs based on context
  - Implement rate limiting on all endpoints
```

#### API Hardening
```yaml
authentication:
  recommendations:
    - Use OAuth 2.0 / OpenID Connect
    - Implement short-lived access tokens (15 min)
    - Use refresh token rotation
    - Require MFA for sensitive operations

  implementation: |
    // JWT configuration
    const token = jwt.sign(payload, secret, {
      expiresIn: '15m',
      algorithm: 'RS256'
    });

rate_limiting:
  global: "1000 requests/minute per IP"
  auth_endpoints: "5 requests/minute per IP"
  implementation: |
    const rateLimit = require('express-rate-limit');

    const apiLimiter = rateLimit({
      windowMs: 60 * 1000,
      max: 100,
      standardHeaders: true,
      legacyHeaders: false,
    });

    const authLimiter = rateLimit({
      windowMs: 60 * 1000,
      max: 5,
    });

    app.use('/api/', apiLimiter);
    app.use('/auth/', authLimiter);

request_validation:
  - Validate Content-Type headers
  - Limit request body size
  - Validate against OpenAPI schema
  - Reject unexpected fields

cors:
  implementation: |
    const cors = require('cors');

    app.use(cors({
      origin: ['https://trusted-domain.com'],
      methods: ['GET', 'POST', 'PUT', 'DELETE'],
      allowedHeaders: ['Content-Type', 'Authorization'],
      credentials: true,
      maxAge: 86400
    }));
```

#### Container Hardening
```dockerfile
# Dockerfile best practices

# Use specific, minimal base image
FROM node:20-alpine AS base

# Use multi-stage builds
FROM base AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM gcr.io/distroless/nodejs20-debian12
WORKDIR /app

# Copy only necessary files
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist

# Run as non-root user
USER 65534:65534

# Expose only necessary ports
EXPOSE 3000

# Use ENTRYPOINT for immutability
ENTRYPOINT ["node", "dist/index.js"]
```

```yaml
# Kubernetes security context
apiVersion: v1
kind: Pod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault

  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        limits:
          memory: "256Mi"
          cpu: "200m"
        requests:
          memory: "128Mi"
          cpu: "100m"
```

#### Infrastructure Hardening
```yaml
secrets_management:
  do_not:
    - Hardcode secrets in code
    - Commit .env files
    - Log sensitive data
    - Use weak encryption

  do:
    - Use environment variables
    - Use secret managers (AWS Secrets Manager, HashiCorp Vault)
    - Rotate secrets regularly
    - Encrypt secrets at rest and in transit

  implementation:
    aws: |
      const { SecretsManager } = require('@aws-sdk/client-secrets-manager');
      const client = new SecretsManager({ region: 'us-east-1' });
      const secret = await client.getSecretValue({ SecretId: 'my-secret' });

network_security:
  - Use private subnets for databases
  - Implement network segmentation
  - Enable VPC flow logs
  - Use security groups with least privilege

logging_monitoring:
  - Enable audit logging
  - Set up alerting for anomalies
  - Monitor for privilege escalation
  - Track configuration changes
  - Implement log rotation
```

## Output Format

```
═══════════════════════════════════════════════════════════
                SECURITY HARDENING REPORT
═══════════════════════════════════════════════════════════

Target: Web Application + API
Project: ./

───────────────────────────────────────────────────────────
                    CURRENT STATUS
───────────────────────────────────────────────────────────

Security Headers:
  ✓ X-Content-Type-Options configured
  ✗ Content-Security-Policy missing
  ✗ Strict-Transport-Security missing
  ✗ X-Frame-Options missing

Authentication:
  ✓ JWT implemented
  ✗ Token expiration too long (24h → recommend 15m)
  ✗ No rate limiting on auth endpoints

Dependencies:
  ✗ 3 packages with known vulnerabilities
  ✗ helmet package not installed

───────────────────────────────────────────────────────────
                  RECOMMENDATIONS
───────────────────────────────────────────────────────────

CRITICAL (Do Immediately)
─────────────────────────

1. Add security headers middleware
   File: src/app.ts

   npm install helmet

   // Add to app.ts
   import helmet from 'helmet';
   app.use(helmet());

2. Fix vulnerable dependencies
   Run: npm audit fix

HIGH (Within 7 Days)
────────────────────

3. Add rate limiting to auth endpoints
   File: src/routes/auth.ts

   npm install express-rate-limit

   import rateLimit from 'express-rate-limit';
   const authLimiter = rateLimit({
     windowMs: 60 * 1000,
     max: 5
   });
   router.use(authLimiter);

4. Reduce JWT expiration time
   File: src/auth/jwt.ts

   // Change from
   expiresIn: '24h'
   // To
   expiresIn: '15m'

MEDIUM (Within 30 Days)
───────────────────────

5. Add Content Security Policy
6. Implement refresh token rotation
7. Add input validation middleware
8. Set up security monitoring

───────────────────────────────────────────────────────────
                   COMPLIANCE CHECK
───────────────────────────────────────────────────────────

OWASP Top 10 Coverage:
  A01 Access Control    ⚠️  Partial (needs RBAC review)
  A02 Cryptography      ✓  TLS enabled, strong algorithms
  A03 Injection         ⚠️  Needs input validation
  A04 Insecure Design   ✓  Follows secure patterns
  A05 Misconfiguration  ✗  Missing security headers
  A06 Components        ✗  Vulnerable dependencies
  A07 Auth Failures     ⚠️  Token expiration too long
  A08 Data Integrity    ✓  CI/CD secure
  A09 Logging           ⚠️  Needs audit logging
  A10 SSRF              ✓  No external URL handling

Overall Compliance: 60%

───────────────────────────────────────────────────────────
                   ACTION CHECKLIST
───────────────────────────────────────────────────────────

[ ] Install and configure helmet
[ ] Run npm audit fix
[ ] Add rate limiting middleware
[ ] Reduce JWT expiration to 15m
[ ] Add CSP header
[ ] Implement refresh tokens
[ ] Add request validation
[ ] Set up security monitoring
[ ] Review access control policies
[ ] Add audit logging

───────────────────────────────────────────────────────────
```

## Agent Dispatch
- Primary: @security-auditor
- Support: @devops-engineer (infrastructure), @backend-node/@backend-go (implementation)

## Related Commands
- `/security-scan` - Full security analysis
- `/secret-scan` - Credential detection
- `/review` - Code review with security focus
