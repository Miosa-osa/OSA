---
name: diagnosing-bugs
description: Diagnose broken, failing, incorrect, flaky, or unexpectedly slow software. Use whenever a user reports a bug, regression, crash, hang, visual defect, or unexplained behavior, even if they ask directly for a fix.
tools:
  - file_read
  - file_grep
  - file_glob
  - shell_execute
  - file_edit
triggers:
  - diagnose
  - debug this
  - something is broken
  - regression
---

# Diagnosing Bugs

Find the real failure before changing production code.
Treat a plausible explanation as a hypothesis, not a result.

## Procedure

1. Translate the report into an observable failure and an expected behavior.
2. Reproduce it end to end as closely as possible to the user path.
3. Preserve the failing command, fixture, screenshot, trace, or test as evidence.
4. Minimize the reproduction without changing the failure.
5. Rank concrete hypotheses and identify what observation would distinguish each one.
6. Inspect or instrument the narrowest relevant seam.
7. Add a regression test that fails for the reproduced defect.
8. Make the smallest robust fix at the cause, not at a downstream symptom.
9. Run the regression test, nearby tests, and the original end-to-end reproduction.
10. Report what caused the failure, what changed, and what remains unproven.

## Rules

- Do not edit merely because a suspicious line was found.
- Do not weaken a test to make the current behavior pass.
- For visual bugs, verify in a real terminal or browser at the dimensions and interaction that triggered the report.
- For intermittent bugs, add logging or deterministic scheduling before guessing.
- If the same diagnostic action produces identical evidence repeatedly, change the experiment.

## Completion evidence

A diagnosis is complete only when the evidence distinguishes the chosen cause from credible alternatives.
A fix is complete only when the original user-facing reproduction and the regression test both pass.
