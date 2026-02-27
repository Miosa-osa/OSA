---
globs: ["**/*.ts", "**/*.tsx"]
alwaysApply: false
---

# TypeScript Rules

## Type Safety
- Use strict mode (`"strict": true` in tsconfig)
- Avoid `any` - use `unknown` with type guards instead
- Define explicit return types for functions
- Use branded types for IDs (UserId, OrderId)

## Patterns
```typescript
// Prefer
type UserId = string & { __brand: 'UserId' };
function getUser(id: UserId): User { ... }

// Avoid
function getUser(id: string): User { ... }
```

## Error Handling
```typescript
// Use Result pattern for expected errors
type Result<T, E = Error> = { ok: true; value: T } | { ok: false; error: E };

// Use try/catch for unexpected errors only
```

## Imports
- Use absolute imports with path aliases
- Group imports: external, internal, relative
- No circular dependencies

## Naming
- PascalCase: types, interfaces, classes, components
- camelCase: functions, variables, methods
- SCREAMING_SNAKE: constants
- kebab-case: file names
