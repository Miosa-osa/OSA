---
name: code-review-checklist
description: Quick and deep code review checklists
triggers:
  - review
  - code changes
  - checklist
---

# Code Review Checklist Skill

## Trigger
Activates after any code changes.

## Quick Checklist
- [ ] Code is readable and self-documenting
- [ ] Functions/methods are small and focused
- [ ] No code duplication
- [ ] Error handling is comprehensive
- [ ] No security vulnerabilities
- [ ] Performance is acceptable
- [ ] Tests cover the changes
- [ ] No hardcoded values that should be config

## Deep Checklist (for significant changes)
- [ ] Architecture fits existing patterns
- [ ] API design is consistent
- [ ] Database changes are safe
- [ ] Backward compatibility maintained
- [ ] Logging is sufficient
- [ ] Monitoring/metrics added if needed
