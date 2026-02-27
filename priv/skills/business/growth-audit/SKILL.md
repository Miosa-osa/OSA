---
name: growth-audit
description: Audit domain health, SEO performance, and growth opportunities
tools: [shell_execute, web_search, file_write, memory_save]
trigger: growth|seo|audit|domain|lighthouse|competitor
priority: medium
---

# Growth Audit

Comprehensive audit of digital presence and growth opportunities.

## Capabilities
- DNS and domain health checks via dig/nslookup
- SSL certificate validation and expiry monitoring
- Lighthouse performance scoring (requires lighthouse CLI)
- SEO meta tag analysis
- Competitor domain comparison
- Generate actionable growth recommendations

## Workflow
1. Identify the target domain from user request
2. Run DNS health checks (A, MX, TXT records)
3. Validate SSL certificate chain and expiry
4. Run Lighthouse audit if CLI available
5. Analyze SEO signals (meta tags, robots.txt, sitemap)
6. Compare against competitor domains if specified
7. Generate prioritized recommendations report

## Output
Results saved to ~/.osa/data/audits/{domain}-{date}.json
