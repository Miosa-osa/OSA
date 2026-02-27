---
name: build
description: Build project with intelligent detection
arguments:
  - name: mode
    required: false
    default: development
    description: "development | production | watch"
---

# Build Workflow

Build project with intelligent framework detection.

## Detection

1. **Identify Build System**
   - `package.json` → npm/yarn/pnpm
   - `go.mod` → Go build
   - `Cargo.toml` → Cargo
   - `Makefile` → Make
   - `Dockerfile` → Docker

2. **Identify Framework**
   - Next.js, Vite, SvelteKit, etc.
   - Determine correct build command

## Commands by Framework

### JavaScript/TypeScript

```bash
# Generic
npm run build
yarn build
pnpm build

# Next.js
npm run build  # Creates .next/

# Vite
npm run build  # Creates dist/

# SvelteKit
npm run build  # Creates .svelte-kit/
```

### Go

```bash
# Development
go build -o bin/app ./cmd/app

# Production
CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o bin/app ./cmd/app

# With race detection
go build -race -o bin/app ./cmd/app
```

### Docker

```bash
# Build image
docker build -t app:latest .

# Multi-platform
docker buildx build --platform linux/amd64,linux/arm64 -t app:latest .
```

## Action Steps

1. **Detect Build System**
   - Check project files
   - Identify framework

2. **Set Mode**
   - Development: Fast, with source maps
   - Production: Optimized, minified
   - Watch: Rebuild on changes

3. **Run Build**
   - Execute appropriate command
   - Capture output

4. **Report Results**
   ```
   Build Complete
   --------------
   Framework: Next.js 14
   Mode: Production
   Duration: 23.4s
   Output: .next/

   Bundle Analysis:
   - Total: 245KB (gzipped: 78KB)
   - Largest: vendors.js (120KB)
   ```

5. **On Failure**
   - Show error details
   - Identify root cause
   - Suggest fix

## Common Issues

- **TypeScript errors**: Fix types first
- **Missing dependencies**: Run `npm install`
- **Memory issues**: Increase Node memory
- **Cache issues**: Clear `.next/cache` or equivalent
