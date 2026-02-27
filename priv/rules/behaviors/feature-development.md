---
globs: ["**/*"]
description: "How to approach new feature development. EDIT THIS FILE to add your insights."
---

# Feature Development Behavior Guide

**HUMAN EDIT SECTION** - Add your feature development insights below the line.

## Default Feature Development Protocol

### 1. Understand
- Clarify requirements
- Identify acceptance criteria
- Check for similar existing features

### 2. Brainstorm
- Generate 3 approaches minimum
- Evaluate pros/cons/effort for each
- Consider maintenance burden

### 3. Plan
- Break into subtasks
- Identify dependencies
- Estimate complexity

### 4. Design
- Create ADR if significant
- Design API contracts first
- Consider edge cases upfront

### 5. Implement
- Use TDD when possible
- Small, focused commits
- Keep PRs reviewable (<400 lines)

### 6. Test
- Unit tests for logic
- Integration tests for APIs
- E2E for critical flows

### 7. Review
- Self-review first
- Request peer review
- Address all comments

### 8. Ship
- Feature flag if risky
- Monitor after deploy
- Document if needed

---

## YOUR INSIGHTS (Edit Below)

<!--
Add your own feature development insights here. Examples:

### Our Feature Workflow
- All features need design doc approval first
- Use feature branches: feature/TICKET-description
- Deploy to staging before PR merge

### Architecture Patterns We Use
- Use repository pattern for data access
- All APIs must have OpenAPI spec
- Use event sourcing for audit-critical features

### Code Standards
- Max function length: 50 lines
- Max file length: 300 lines
- Required test coverage: 80%
-->

### Our Feature Development Workflow
<!-- Add your team's workflow -->

### Architecture Patterns We Prefer
<!-- Add preferred patterns -->

### Code Standards
<!-- Add code standards -->

### Common Pitfalls to Avoid
<!-- Add lessons learned -->

### Stakeholders to Involve
<!-- Who needs to approve what -->
