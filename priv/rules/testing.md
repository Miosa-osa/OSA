---
globs: ["**/*.test.*", "**/*.spec.*", "**/test/**", "**/tests/**", "**/__tests__/**"]
alwaysApply: false
---

# Testing Rules

## Test-Driven Development
1. Write failing test first (RED)
2. Write minimum code to pass (GREEN)
3. Refactor while tests pass (REFACTOR)

## Test Structure
```typescript
describe('Component/Function', () => {
  describe('method/scenario', () => {
    it('should [expected behavior] when [condition]', () => {
      // Arrange
      // Act
      // Assert
    });
  });
});
```

## Naming Conventions
- Test files: `*.test.ts` or `*.spec.ts`
- Test description: "should [verb] when [condition]"
- Variables: `expected*`, `actual*`, `mock*`

## Coverage Targets
- Statements: 80%+
- Branches: 75%+
- Functions: 80%+
- Lines: 80%+

## Mocking
```typescript
// Use dependency injection
const mockService = { method: vi.fn() };
const sut = new SystemUnderTest(mockService);

// Verify calls
expect(mockService.method).toHaveBeenCalledWith(expected);
```

## Edge Cases to Test
- Empty inputs
- Null/undefined
- Boundary values
- Error conditions
- Async behavior
- Race conditions (if applicable)
