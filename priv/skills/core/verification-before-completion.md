---
name: verification-before-completion
description: Verify before claiming done
triggers:
  - done
  - complete
  - finished
  - ready
---

# Verification Before Completion Skill

## When This Activates
Before marking any task as complete.

## Checklist
- [ ] Code compiles/builds without errors
- [ ] Code runs without runtime errors
- [ ] All existing tests pass
- [ ] New tests added for new code
- [ ] Edge cases handled
- [ ] Error cases handled
- [ ] No regressions introduced
- [ ] Documentation updated (if needed)
- [ ] Self-review completed
- [ ] Changes committed with clear message

## Output Format
```markdown
## Verification: [Task]

### Build Status
✅ Pass | ❌ Fail

### Test Status  
✅ X/X passing | ❌ Y failures

### Checklist
- [x] Compiles
- [x] Tests pass
- [x] Edge cases
- [x] Documentation

### Overall: ✅ Ready | ❌ Not Ready
[Notes if not ready]
```
