---
name: test
description: Run tests with intelligent detection
arguments:
  - name: scope
    required: false
    description: "all | unit | integration | e2e | file:path"
---

# Test Runner Workflow

Intelligently run tests based on project type and scope.

## Detection

1. **Identify Test Framework**
   - `package.json` → Jest, Vitest, Mocha, Playwright
   - `go.mod` → Go testing
   - `pytest.ini` / `pyproject.toml` → Pytest
   - `Cargo.toml` → Rust tests

2. **Identify Scope**
   - Default: Run tests related to recent changes
   - `all`: Full test suite
   - `unit`: Unit tests only
   - `integration`: Integration tests
   - `e2e`: End-to-end tests
   - `file:path`: Specific file

## Test Commands by Framework

### JavaScript/TypeScript
```bash
# Jest
npm test
npm test -- --coverage
npm test -- path/to/file.test.ts

# Vitest
npx vitest
npx vitest run
npx vitest path/to/file.test.ts

# Playwright
npx playwright test
```

### Go
```bash
go test ./...
go test -v ./...
go test -cover ./...
go test -race ./...
go test ./path/to/package
```

### Python
```bash
pytest
pytest -v
pytest --cov
pytest path/to/test_file.py
```

## Action Steps

1. **Detect Framework**
   - Check project files
   - Identify test runner

2. **Determine Scope**
   - Check recent changes
   - Map to relevant tests

3. **Run Tests**
   - Execute appropriate command
   - Capture output

4. **Report Results**
   ```
   Tests: 47 passed, 2 failed, 1 skipped
   Coverage: 78%
   Duration: 12.3s

   Failed Tests:
   - test_user_login: AssertionError at line 45
   - test_api_response: Timeout after 5000ms
   ```

5. **On Failure**
   - Show failing test details
   - Suggest fix if obvious
   - Offer to debug with @debugger

## Coverage Targets

- Unit tests: 80%+
- Integration: 60%+
- Critical paths: 100%
