---
globs: ["**/*"]
description: "How to approach debugging problems. EDIT THIS FILE to add your insights."
---

# Debugging Behavior Guide

**HUMAN EDIT SECTION** - Add your debugging insights below the line.

## Default Debugging Protocol

### 1. Reproduce
- Get exact steps to reproduce
- Confirm it's consistent
- Find minimum reproduction case

### 2. Isolate
- Narrow down the scope
- Check recent changes (git log, git diff)
- Identify affected components

### 3. Hypothesize
- Form 2-3 theories ranked by likelihood
- Plan how to test each

### 4. Test
- Test most likely hypothesis first
- Use debugger/logs strategically
- Binary search if needed (git bisect)

### 5. Fix
- Fix root cause, not symptoms
- Keep fix minimal and focused
- Don't refactor while fixing

### 6. Verify
- Confirm bug is fixed
- Check for regressions
- Test edge cases

### 7. Prevent
- Add regression test
- Document if needed
- Consider monitoring/alerting

---

## YOUR INSIGHTS (Edit Below)

<!--
Add your own debugging insights here. Examples:

### Our Common Bug Patterns
- Auth bugs: Usually token expiration or Redis TTL issues
- UI bugs: Check Svelte reactivity first
- API bugs: Validate request/response schemas

### Our Debugging Tools
- Use `make debug` to start with verbose logging
- Check Sentry for error traces
- Use `kubectl logs` for production issues

### Project-Specific Notes
- Database connection issues: Check connection pool settings
- Performance bugs: Profile with pprof first
- Memory leaks: Check goroutine counts
-->

### Common Bug Patterns in Our Codebase
<!-- Add patterns you've noticed -->

### Preferred Debugging Tools
<!-- Add your team's debugging tools -->

### Project-Specific Debugging Notes
<!-- Add project-specific insights -->

### Lessons Learned
<!-- Add debugging lessons from past bugs -->
