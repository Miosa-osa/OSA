---
name: security-scan
description: Run comprehensive security scan on codebase
---

# Security Scan Command

Run full security analysis including SAST, SCA, secret detection, and IaC scanning.

## Usage
```
/security-scan [path] [--severity=<low|medium|high|critical>] [--format=<json|sarif|table>]
```

## Execution Workflow

### Step 1: Project Detection
Detect project type and determine applicable scanners.

```bash
# Detect project types
PROJECT_TYPES=""
[ -f "package.json" ] && PROJECT_TYPES="$PROJECT_TYPES node"
[ -f "go.mod" ] && PROJECT_TYPES="$PROJECT_TYPES go"
[ -f "requirements.txt" ] || [ -f "pyproject.toml" ] && PROJECT_TYPES="$PROJECT_TYPES python"
[ -f "Gemfile" ] && PROJECT_TYPES="$PROJECT_TYPES ruby"
[ -f "Dockerfile" ] && PROJECT_TYPES="$PROJECT_TYPES docker"
[ -d "terraform" ] || ls *.tf 2>/dev/null && PROJECT_TYPES="$PROJECT_TYPES terraform"
[ -d ".github" ] && PROJECT_TYPES="$PROJECT_TYPES github-actions"
echo "Detected: $PROJECT_TYPES"
```

### Step 2: SAST Scan (Static Analysis)
```bash
# Semgrep for multi-language SAST
semgrep scan \
  --config auto \
  --config p/security-audit \
  --config p/owasp-top-ten \
  --config p/secrets \
  --sarif \
  --output semgrep-results.sarif \
  .

# Language-specific scanners
# Python
bandit -r . -f sarif -o bandit-results.sarif

# Go
gosec -fmt sarif -out gosec-results.sarif ./...

# JavaScript/TypeScript - using ESLint security plugin
eslint --plugin security --format json --output-file eslint-security.json .
```

### Step 3: SCA Scan (Dependency Vulnerabilities)
```bash
# Universal scanner with Trivy
trivy fs \
  --severity HIGH,CRITICAL \
  --format sarif \
  --output trivy-fs.sarif \
  .

# Language-specific
# Node.js
npm audit --json > npm-audit.json

# Python
pip-audit --format json --output pip-audit.json

# Go
go list -json -m all | nancy sleuth --output json > nancy.json

# Ruby
bundle audit check --format json > bundle-audit.json
```

### Step 4: Secret Detection
```bash
# Gitleaks for secret scanning
gitleaks detect \
  --source . \
  --report-format sarif \
  --report-path gitleaks.sarif \
  --baseline-path .gitleaks-baseline.json

# TruffleHog for verified secrets
trufflehog filesystem . \
  --only-verified \
  --json \
  > trufflehog.json
```

### Step 5: IaC Security Scan
```bash
# Terraform/Kubernetes/Docker
trivy config \
  --severity HIGH,CRITICAL \
  --format sarif \
  --output trivy-config.sarif \
  .

# Checkov for comprehensive IaC
checkov -d . \
  --quiet \
  --compact \
  --output-file-path . \
  --output sarif

# Dockerfile specific
hadolint Dockerfile --format sarif > hadolint.sarif 2>/dev/null || true
```

### Step 6: Container Scan (if Docker present)
```bash
# Build and scan container if Dockerfile exists
if [ -f "Dockerfile" ]; then
  # Build image
  docker build -t security-scan-target:latest .

  # Scan with Trivy
  trivy image \
    --severity HIGH,CRITICAL \
    --format sarif \
    --output trivy-image.sarif \
    security-scan-target:latest
fi
```

### Step 7: Aggregate and Report
Combine all findings and present prioritized results.

## Output Format

```
═══════════════════════════════════════════════════════════
                    SECURITY SCAN REPORT
═══════════════════════════════════════════════════════════

Target: ./
Scan Time: 2024-01-26 14:30:00
Duration: 45 seconds

───────────────────────────────────────────────────────────
                      SUMMARY
───────────────────────────────────────────────────────────

┌──────────────┬──────────┬───────┬────────┬─────┐
│ Category     │ Critical │ High  │ Medium │ Low │
├──────────────┼──────────┼───────┼────────┼─────┤
│ SAST         │    1     │   3   │   5    │  2  │
│ Dependencies │    2     │   5   │   8    │  3  │
│ Secrets      │    1     │   0   │   0    │  0  │
│ IaC          │    0     │   2   │   3    │  1  │
├──────────────┼──────────┼───────┼────────┼─────┤
│ TOTAL        │    4     │  10   │  16    │  6  │
└──────────────┴──────────┴───────┴────────┴─────┘

───────────────────────────────────────────────────────────
                  CRITICAL FINDINGS (4)
───────────────────────────────────────────────────────────

[CRIT-001] SQL Injection
  File: src/db/queries.ts:45
  CWE: CWE-89
  OWASP: A03:2021-Injection
  Description: User input directly concatenated in SQL query

  Code:
    const query = `SELECT * FROM users WHERE id = ${userId}`;

  Remediation: Use parameterized queries
    const query = 'SELECT * FROM users WHERE id = $1';
    db.query(query, [userId]);

[CRIT-002] Hardcoded AWS Access Key
  File: src/config.ts:12
  Type: Secret Exposure
  Match: AKIA52XXXXXXXXXX

  Remediation:
    1. Rotate this key immediately
    2. Use AWS Secrets Manager or environment variables
    3. Add to .gitignore if local config

[CRIT-003] Critical CVE in lodash@4.17.20
  CVE: CVE-2021-23337
  CVSS: 9.8
  Affected: package.json

  Remediation: npm install lodash@4.17.21

[CRIT-004] Critical CVE in django@3.2.0
  CVE: CVE-2023-XXXXX
  CVSS: 9.1
  Affected: requirements.txt

  Remediation: pip install django>=3.2.18

───────────────────────────────────────────────────────────
                    HIGH FINDINGS (10)
───────────────────────────────────────────────────────────

[HIGH-001] XSS via dangerouslySetInnerHTML
  File: src/components/UserContent.tsx:23
  CWE: CWE-79
  ...

───────────────────────────────────────────────────────────
                   OWASP TOP 10 COVERAGE
───────────────────────────────────────────────────────────

A01 Broken Access Control     ⚠️  1 issue found
A02 Cryptographic Failures    ✅ No issues
A03 Injection                 🚨 2 issues found
A04 Insecure Design           ✅ No issues
A05 Security Misconfiguration ⚠️  3 issues found
A06 Vulnerable Components     🚨 7 issues found
A07 Auth Failures             ✅ No issues
A08 Data Integrity            ✅ No issues
A09 Logging Failures          ⚠️  1 issue found
A10 SSRF                      ✅ No issues

───────────────────────────────────────────────────────────
                   RECOMMENDED ACTIONS
───────────────────────────────────────────────────────────

IMMEDIATE (within 24 hours):
  1. Fix SQL injection in src/db/queries.ts
  2. Rotate exposed AWS key
  3. Update lodash to 4.17.21

SHORT-TERM (within 7 days):
  1. Update all HIGH severity dependencies
  2. Fix XSS vulnerabilities
  3. Add security headers to nginx config

LONG-TERM:
  1. Implement dependency update automation
  2. Add security scanning to CI/CD
  3. Schedule quarterly security reviews

───────────────────────────────────────────────────────────
                      SCAN COMPLETE
───────────────────────────────────────────────────────────

Full reports saved to:
  - semgrep-results.sarif
  - trivy-fs.sarif
  - gitleaks.sarif
```

## Agent Dispatch
- Primary: @security-auditor
- Support: @dependency-analyzer (for SCA), @devops-engineer (for IaC)

## Related Commands
- `/vuln-check` - Quick dependency vulnerability scan
- `/secret-scan` - Secret detection only
- `/pentest` - Active penetration testing
- `/harden` - Security hardening recommendations
