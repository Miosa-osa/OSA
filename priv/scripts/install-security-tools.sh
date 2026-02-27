#!/bin/bash
# Install Security CLI Tools for OSA Agent
# Run: chmod +x ~/.claude/scripts/install-security-tools.sh && ~/.claude/scripts/install-security-tools.sh

set -e

echo "═══════════════════════════════════════════════════════════"
echo "           OSA Agent Security Tools Installation"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Detect OS
OS="$(uname -s)"
ARCH="$(uname -m)"

# Check for package managers
HAS_BREW=false
HAS_GO=false
HAS_PIP=false
HAS_NPM=false

command -v brew >/dev/null 2>&1 && HAS_BREW=true
command -v go >/dev/null 2>&1 && HAS_GO=true
command -v pip3 >/dev/null 2>&1 && HAS_PIP=true
command -v npm >/dev/null 2>&1 && HAS_NPM=true

echo "System: $OS $ARCH"
echo "Package managers: brew=$HAS_BREW go=$HAS_GO pip=$HAS_PIP npm=$HAS_NPM"
echo ""

install_tool() {
    local name=$1
    local brew_pkg=$2
    local go_pkg=$3
    local pip_pkg=$4
    local npm_pkg=$5

    if command -v "$name" >/dev/null 2>&1; then
        echo "✓ $name already installed: $(command -v $name)"
        return 0
    fi

    echo "Installing $name..."

    if $HAS_BREW && [ -n "$brew_pkg" ]; then
        brew install "$brew_pkg" && return 0
    fi

    if $HAS_GO && [ -n "$go_pkg" ]; then
        go install "$go_pkg" && return 0
    fi

    if $HAS_PIP && [ -n "$pip_pkg" ]; then
        pip3 install "$pip_pkg" && return 0
    fi

    if $HAS_NPM && [ -n "$npm_pkg" ]; then
        npm install -g "$npm_pkg" && return 0
    fi

    echo "⚠ Could not install $name (no suitable package manager)"
    return 1
}

echo "───────────────────────────────────────────────────────────"
echo "                  SECRET DETECTION"
echo "───────────────────────────────────────────────────────────"

# Gitleaks - Secret detection
install_tool "gitleaks" "gitleaks" "github.com/gitleaks/gitleaks/v8@latest" "" ""

# TruffleHog - Deep secret scanning with verification
install_tool "trufflehog" "trufflehog" "" "trufflehog" ""

# detect-secrets - Yelp's secret detector
install_tool "detect-secrets" "" "" "detect-secrets" ""

echo ""
echo "───────────────────────────────────────────────────────────"
echo "                  SAST SCANNERS"
echo "───────────────────────────────────────────────────────────"

# Semgrep - Multi-language SAST
install_tool "semgrep" "" "" "semgrep" ""

# Bandit - Python security linter
install_tool "bandit" "" "" "bandit" ""

# Gosec - Go security checker
install_tool "gosec" "" "github.com/securego/gosec/v2/cmd/gosec@latest" "" ""

echo ""
echo "───────────────────────────────────────────────────────────"
echo "                  DEPENDENCY SCANNING"
echo "───────────────────────────────────────────────────────────"

# Trivy - Comprehensive vulnerability scanner
install_tool "trivy" "trivy" "" "" ""

# pip-audit - Python dependency audit
install_tool "pip-audit" "" "" "pip-audit" ""

# OSV Scanner - Google's OSV database scanner
install_tool "osv-scanner" "" "github.com/google/osv-scanner/cmd/osv-scanner@latest" "" ""

# Snyk (optional, requires account)
echo "ℹ Snyk requires account. Install via: npm install -g snyk && snyk auth"

echo ""
echo "───────────────────────────────────────────────────────────"
echo "                  VULNERABILITY SCANNING"
echo "───────────────────────────────────────────────────────────"

# Nuclei - Template-based vuln scanner
install_tool "nuclei" "nuclei" "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest" "" ""

# Nikto - Web server scanner
install_tool "nikto" "nikto" "" "" ""

# SQLMap - SQL injection tester
install_tool "sqlmap" "sqlmap" "" "sqlmap" ""

echo ""
echo "───────────────────────────────────────────────────────────"
echo "                  INFRASTRUCTURE SECURITY"
echo "───────────────────────────────────────────────────────────"

# Checkov - IaC scanner
install_tool "checkov" "" "" "checkov" ""

# TFSec - Terraform security
install_tool "tfsec" "tfsec" "github.com/aquasecurity/tfsec/cmd/tfsec@latest" "" ""

# Hadolint - Dockerfile linter
install_tool "hadolint" "hadolint" "" "" ""

echo ""
echo "───────────────────────────────────────────────────────────"
echo "                  RECONNAISSANCE"
echo "───────────────────────────────────────────────────────────"

# Nmap - Network scanner
install_tool "nmap" "nmap" "" "" ""

# Subfinder - Subdomain discovery
install_tool "subfinder" "" "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest" "" ""

# Httpx - HTTP probe
install_tool "httpx" "" "github.com/projectdiscovery/httpx/cmd/httpx@latest" "" ""

echo ""
echo "───────────────────────────────────────────────────────────"
echo "                  PRE-COMMIT HOOKS"
echo "───────────────────────────────────────────────────────────"

# Pre-commit framework
install_tool "pre-commit" "pre-commit" "" "pre-commit" ""

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "                  INSTALLATION COMPLETE"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Verify installation:"
echo "───────────────────────────────────────────────────────────"

TOOLS="gitleaks semgrep trivy nuclei bandit"
for tool in $TOOLS; do
    if command -v "$tool" >/dev/null 2>&1; then
        VERSION=$($tool --version 2>/dev/null | head -1 || echo "installed")
        echo "✓ $tool: $VERSION"
    else
        echo "✗ $tool: not installed"
    fi
done

echo ""
echo "───────────────────────────────────────────────────────────"
echo "                    NEXT STEPS"
echo "───────────────────────────────────────────────────────────"
echo ""
echo "1. Setup pre-commit hooks in your project:"
echo "   cp ~/.claude/pre-commit-config.yaml ./.pre-commit-config.yaml"
echo "   pre-commit install"
echo ""
echo "2. Configure Gitleaks baseline:"
echo "   cp ~/.claude/gitleaks.toml ./.gitleaks.toml"
echo "   gitleaks detect --report-path .gitleaks-baseline.json"
echo ""
echo "3. Run security scan:"
echo "   /security-scan"
echo ""
echo "4. Configure CI/CD security pipeline"
echo "   See: ~/.claude/docs/security-cicd.md"
echo ""
