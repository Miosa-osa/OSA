---
globs: ["src/components/**/*.tsx", "src/components/**/*.svelte", "src/lib/components/**/*.svelte"]
alwaysApply: false
---

# Component Rules

## Component Structure
```
components/
├── ui/                 # Generic UI components (Button, Input, Modal)
├── features/           # Feature-specific components
├── layouts/            # Layout components
└── shared/             # Shared/cross-cutting components
```

## Naming
- PascalCase for component files: `UserCard.tsx`, `LoginForm.svelte`
- Match filename to component name
- Descriptive names: `UserProfileCard` not `Card`

## Props
```typescript
// Define explicit prop types
interface UserCardProps {
  user: User;
  onSelect?: (user: User) => void;
  variant?: 'default' | 'compact';
}

// Use defaults
function UserCard({ user, variant = 'default' }: UserCardProps) { ... }
```

## Accessibility
- Always include `aria-label` for interactive elements
- Use semantic HTML (`button`, `nav`, `main`, `article`)
- Support keyboard navigation
- Ensure color contrast ratios (WCAG 2.1 AA)

```tsx
// Good
<button aria-label="Close modal" onClick={onClose}>
  <XIcon aria-hidden="true" />
</button>

// Bad
<div onClick={onClose}>X</div>
```

## State Management
- Keep state as close to usage as possible
- Lift state only when needed for sharing
- Use context sparingly (performance implications)

## Performance
- Memoize expensive computations
- Use virtualization for long lists
- Lazy load below-fold components
- Optimize re-renders

```tsx
// React
const expensiveValue = useMemo(() => compute(data), [data]);
const memoizedCallback = useCallback(() => handle(id), [id]);

// Svelte
$: expensiveValue = compute(data);
```

## Error Boundaries
- Wrap feature sections in error boundaries
- Provide fallback UI
- Log errors for debugging
