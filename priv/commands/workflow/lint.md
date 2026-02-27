---
name: lint
description: Run linting with auto-fix
arguments:
  - name: fix
    required: false
    default: "true"
---

# Lint Workflow

Run linting and formatting with intelligent detection.

## Detection

1. **Identify Linter**
   - `eslint.config.*` / `.eslintrc.*` → ESLint
   - `biome.json` → Biome
   - `prettier.config.*` / `.prettierrc` → Prettier
   - `.golangci.yml` → golangci-lint
   - `pyproject.toml` (ruff) → Ruff
   - `rustfmt.toml` → rustfmt

## Commands by Tool

### JavaScript/TypeScript

```bash
# ESLint
npx eslint . --fix
npx eslint src/ --fix

# Biome
npx biome check --write .
npx biome format --write .

# Prettier
npx prettier --write .
npx prettier --write "src/**/*.{ts,tsx}"
```

### Go

```bash
# Format
go fmt ./...
gofmt -w .

# Lint
golangci-lint run
golangci-lint run --fix
```

### Python

```bash
# Ruff (fast)
ruff check . --fix
ruff format .

# Black
black .

# isort
isort .
```

## Action Steps

1. **Detect Tools**
   - Check config files
   - Identify available linters

2. **Run Linter**
   - With `--fix` if requested
   - Capture output

3. **Report Results**
   ```
   Linting Complete
   ----------------
   Files checked: 127
   Issues found: 12
   Auto-fixed: 10
   Remaining: 2

   Manual fixes needed:
   - src/utils.ts:45 - Unexpected any type
   - src/api.ts:23 - Missing return type
   ```

4. **On Issues**
   - Show remaining issues
   - Offer to fix manually
   - Explain why auto-fix couldn't help

## Pre-Commit Integration

Consider running lint before commit:
```bash
# In .husky/pre-commit or similar
npm run lint
```
