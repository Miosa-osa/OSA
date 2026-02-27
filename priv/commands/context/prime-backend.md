---
name: prime-backend
description: Load Go backend development context
---

# Prime: Go Backend Development

## Tech Stack
- **Go 1.21+**: Latest features, generics
- **Database**: pgx for PostgreSQL
- **Cache**: go-redis for Redis
- **HTTP**: Chi or standard library
- **Logging**: slog (structured)

## Project Structure
```
cmd/
  api/
    main.go           # Entry point
internal/
  handler/            # HTTP handlers
  service/            # Business logic
  repository/         # Data access
  domain/             # Domain models
  middleware/         # HTTP middleware
pkg/                  # Shared packages
migrations/           # Database migrations
```

## Patterns
```go
// Constructor injection
func NewService(repo Repository, cache Cache) *Service {
    return &Service{repo: repo, cache: cache}
}

// Error handling
if err != nil {
    return fmt.Errorf("operation failed: %w", err)
}

// Context propagation
func (s *Service) DoWork(ctx context.Context) error {
    // Always use ctx
}
```

## Standards
- Interface-driven design
- Proper error wrapping
- Structured logging with context
- Graceful shutdown
- No global state
