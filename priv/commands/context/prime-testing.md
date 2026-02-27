---
name: prime-testing
description: Load testing and quality assurance context
---

# Prime: Testing & Quality Assurance

## Testing Pyramid
- **Unit (70%)**: Fast, isolated, mock dependencies
- **Integration (20%)**: Real interactions, fewer mocks
- **E2E (10%)**: Critical user flows only

## Frameworks
- **React**: Vitest + React Testing Library + MSW
- **Svelte**: Vitest + Testing Library + Playwright
- **Go**: testing + testify + gomock
- **Node**: Vitest/Jest + Supertest

## Test Structure (AAA)
```typescript
describe('Component', () => {
  it('should do something when condition', async () => {
    // Arrange
    const props = { ... };
    
    // Act
    render(<Component {...props} />);
    await userEvent.click(screen.getByRole('button'));
    
    // Assert
    expect(screen.getByText('Result')).toBeInTheDocument();
  });
});
```

## Standards
- Descriptive names: "should X when Y"
- One focus per test
- No test interdependence
- Mock external services (MSW for HTTP)
- Test edge cases and errors
- NO flaky tests
