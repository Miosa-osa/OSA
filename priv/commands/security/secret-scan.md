---
name: secret-scan
description: Detect hardcoded secrets and credentials in codebase
---

# Secret Scan Command

Detect hardcoded secrets, API keys, credentials, and sensitive data in the codebase.

## Usage
```
/secret-scan [path] [--history] [--baseline] [--verify]
```

## Options
- `--history` - Scan entire git history (slower but thorough)
- `--baseline` - Create/update baseline for known false positives
- `--verify` - Attempt to verify if detected secrets are active

## Execution Workflow

### Step 1: Current State Scan
```bash
# Gitleaks for fast detection
gitleaks detect \
  --source . \
  --report-format json \
  --report-path gitleaks-report.json \
  --baseline-path .gitleaks-baseline.json \
  --verbose
```

### Step 2: Verified Secrets (if --verify)
```bash
# TruffleHog verifies if secrets are active
trufflehog filesystem . \
  --only-verified \
  --json \
  > trufflehog-verified.json
```

### Step 3: Git History Scan (if --history)
```bash
# Scan entire git history
gitleaks detect \
  --source . \
  --log-level debug \
  --report-format json \
  --report-path gitleaks-history.json

# TruffleHog git history
trufflehog git file://. \
  --json \
  > trufflehog-history.json
```

### Step 4: Baseline Management (if --baseline)
```bash
# Create new baseline from current findings
gitleaks detect \
  --source . \
  --report-path .gitleaks-baseline.json

# Or using detect-secrets
detect-secrets scan > .secrets.baseline
detect-secrets audit .secrets.baseline
```

## Secret Categories Detected

### Cloud Provider Credentials
| Type | Pattern | Severity |
|------|---------|----------|
| AWS Access Key | `AKIA[0-9A-Z]{16}` | CRITICAL |
| AWS Secret Key | 40-char base64 | CRITICAL |
| GCP Service Account | JSON key file | CRITICAL |
| Azure Client Secret | GUID format | CRITICAL |

### API Keys & Tokens
| Type | Pattern | Severity |
|------|---------|----------|
| GitHub PAT | `ghp_[A-Za-z0-9]{36}` | CRITICAL |
| GitHub OAuth | `gho_[A-Za-z0-9]{36}` | CRITICAL |
| Stripe Live Key | `sk_live_[A-Za-z0-9]{24}` | CRITICAL |
| Stripe Test Key | `sk_test_[A-Za-z0-9]{24}` | LOW |
| Slack Token | `xox[baprs]-...` | HIGH |
| Slack Webhook | `hooks.slack.com/...` | HIGH |

### Certificates & Keys
| Type | Pattern | Severity |
|------|---------|----------|
| RSA Private Key | `-----BEGIN RSA PRIVATE KEY-----` | CRITICAL |
| SSH Private Key | `-----BEGIN OPENSSH PRIVATE KEY-----` | CRITICAL |
| PGP Private Key | `-----BEGIN PGP PRIVATE KEY-----` | CRITICAL |
| X.509 Certificate | `-----BEGIN CERTIFICATE-----` | MEDIUM |

### Database & Connection Strings
| Type | Pattern | Severity |
|------|---------|----------|
| MongoDB URI | `mongodb://user:pass@...` | CRITICAL |
| PostgreSQL URI | `postgres://user:pass@...` | CRITICAL |
| MySQL URI | `mysql://user:pass@...` | CRITICAL |
| Redis URI | `redis://user:pass@...` | HIGH |

### Other Secrets
| Type | Pattern | Severity |
|------|---------|----------|
| JWT Token | `eyJ...` (3 parts) | HIGH |
| Basic Auth | `Authorization: Basic ...` | HIGH |
| Hardcoded Password | `password = "..."` | HIGH |

## Output Format

```
═══════════════════════════════════════════════════════════
                    SECRET SCAN REPORT
═══════════════════════════════════════════════════════════

Scan Mode: Current State + History
Target: ./
Baseline: .gitleaks-baseline.json (15 known issues)

───────────────────────────────────────────────────────────
                   VERIFIED SECRETS (2)
───────────────────────────────────────────────────────────
These secrets have been verified as ACTIVE and must be
rotated immediately!

🚨 [VERIFIED] AWS Access Key
   File: src/config/aws.js:15
   Value: AKIA52XXXXXXXXXXXXXXXXXX
   Status: ACTIVE (verified via AWS API)
   Last Used: 2024-01-25

   IMMEDIATE ACTION REQUIRED:
   1. Go to AWS Console → IAM → Access Keys
   2. Deactivate this key
   3. Create new key and update via Secrets Manager
   4. Monitor CloudTrail for unauthorized usage

🚨 [VERIFIED] GitHub Personal Access Token
   File: scripts/deploy.sh:42
   Value: ghp_xxxx...xxxx
   Status: ACTIVE (verified via GitHub API)
   Scopes: repo, workflow, admin:org

   IMMEDIATE ACTION REQUIRED:
   1. Go to GitHub → Settings → Developer settings
   2. Revoke this token
   3. Create new token with minimal scopes
   4. Use GitHub Actions secrets instead

───────────────────────────────────────────────────────────
                 UNVERIFIED SECRETS (5)
───────────────────────────────────────────────────────────
These patterns match known secret formats but could not
be verified. Review and rotate if legitimate.

⚠️  [HIGH] Stripe API Key (possibly live)
    File: src/payment/stripe.ts:8
    Pattern: sk_live_*
    Confidence: 90%

⚠️  [HIGH] Database Connection String
    File: config/database.yml:12
    Pattern: postgres://user:password@...
    Confidence: 85%

⚠️  [MEDIUM] Generic API Key
    File: src/services/api.js:23
    Pattern: api_key = "..."
    Confidence: 70%

───────────────────────────────────────────────────────────
                 HISTORICAL SECRETS (3)
───────────────────────────────────────────────────────────
Secrets found in git history. Even if removed from current
code, they may be exposed.

📜 [CRITICAL] AWS Secret Key (removed in abc123)
   Commit: def456 (2023-06-15)
   Author: developer@example.com
   File: config.py (deleted)

   ACTION: Key may still be valid. Rotate immediately.

───────────────────────────────────────────────────────────
                   FALSE POSITIVES (8)
───────────────────────────────────────────────────────────
These were detected but appear to be test/example data:

✓ test/fixtures/mock-keys.json (test data)
✓ docs/api-example.md (documentation)
✓ .env.example (template file)

───────────────────────────────────────────────────────────
                    RECOMMENDATIONS
───────────────────────────────────────────────────────────

1. ROTATE ALL VERIFIED SECRETS IMMEDIATELY
   - AWS keys: Use AWS Secrets Manager or SSM Parameter Store
   - GitHub tokens: Use GitHub Actions secrets
   - Database: Use connection pooling with IAM auth

2. PREVENT FUTURE LEAKS
   - Add pre-commit hook: gitleaks detect --pre-commit
   - Update .gitignore for sensitive files
   - Use environment variables for all secrets

3. CLEAN GIT HISTORY (if critical secrets found)
   $ git filter-branch --force --index-filter \
     'git rm --cached --ignore-unmatch path/to/secret' \
     --prune-empty --tag-name-filter cat -- --all

   Or use BFG Repo-Cleaner:
   $ bfg --delete-files secret.key

4. ADD TO BASELINE (for legitimate false positives)
   $ gitleaks detect --report-path .gitleaks-baseline.json

───────────────────────────────────────────────────────────
```

## Baseline Configuration

To reduce false positives, create `.gitleaks.toml`:

```toml
[allowlist]
paths = [
  '''test/.*''',
  '''\.env\.example$''',
  '''docs/.*\.md$''',
]

regexes = [
  '''(?i)example.*key''',
  '''(?i)test.*secret''',
]

stopwords = [
  "example",
  "test",
  "dummy",
  "placeholder",
]
```

## Agent Dispatch
- Primary: @security-auditor
- Escalate to: Human security team for verified active secrets

## Related Commands
- `/security-scan` - Full security analysis
- `/harden` - Security hardening recommendations
