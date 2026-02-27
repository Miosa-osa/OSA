---
name: test-driven-development
description: Write tests before implementation
triggers:
  - write feature
  - add functionality
  - implement
---

# Test-Driven Development Skill

## When This Activates
When writing new features or adding functionality.

## Process (Red-Green-Refactor)
1. **RED** - Write a failing test that defines desired behavior
2. **GREEN** - Write minimum code to make test pass
3. **REFACTOR** - Improve code quality while keeping tests green

## Rules
- Test MUST be written before implementation
- Test MUST fail initially
- Implementation MUST be minimal
- Refactoring MUST NOT break tests

## Output Format
```markdown
## TDD: [Feature]

### Test (Red Phase)
```[language]
// Test code that will fail
```

### Implementation (Green Phase)
```[language]
// Minimal code to pass
```

### Refactor
[Improvements made]
```
