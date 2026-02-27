---
name: prime-devops
description: Load DevOps and infrastructure context
---

# Prime: DevOps & Infrastructure

## Tech Stack
- **Containers**: Docker, multi-stage builds
- **Cloud**: GCP (Cloud Run, Cloud SQL, GCS)
- **CI/CD**: GitHub Actions
- **IaC**: Terraform (when needed)

## Docker Best Practices
```dockerfile
# Multi-stage build
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY . .
USER node
CMD ["node", "dist/index.js"]
```

## GitHub Actions Pattern
```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
      - run: npm ci
      - run: npm test
```

## Standards
- Always use health checks
- Non-root user in containers
- Secrets via environment/secret manager
- Immutable deployments
- Rollback capability
