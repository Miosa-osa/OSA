---
name: test-driven-development
description: Build features and bug fixes test first using a strict red, green, refactor loop. Use for TDD requests, regression tests, behavior changes with clear acceptance criteria, and risky logic that benefits from executable specification.
tools:
  - file_read
  - file_grep
  - file_glob
  - file_write
  - file_edit
  - shell_execute
triggers:
  - test driven
  - tdd
  - red green refactor
  - regression test
---

# Test-Driven Development

Use tests to define the behavior before implementing it.

## Red

1. Identify the narrowest externally meaningful behavior.
2. Find the nearest existing test style and harness.
3. Write one focused test using the public interface or real user surface.
4. Run it and confirm it fails for the intended reason.
5. If it passes immediately, the test does not prove the requested change.

## Green

1. Implement the smallest production change that satisfies the behavior.
2. Run the focused test.
3. Run nearby tests that exercise the same module or seam.
4. Keep unrelated cleanup out of the green step.

## Refactor

1. Remove duplication and clarify names without changing behavior.
2. Keep the tests green after each meaningful change.
3. Run formatting, static checks, and the proportionate broader suite.

## Test quality

- Prefer observable outcomes over implementation details.
- Include meaningful failure messages for complex invariants.
- Avoid sleeps when a deterministic signal is available.
- Do not mock the behavior under test.
- For a bug, preserve the original reproduction as a regression test whenever practical.
