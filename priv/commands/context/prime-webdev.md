---
name: prime-webdev
description: Load React/Next.js/TypeScript frontend context
---

# Prime: Web Development (React/Next.js)

## Tech Stack
- **React 18+**: Server Components, Hooks, Suspense
- **Next.js 14+**: App Router, RSC, Server Actions
- **TypeScript**: Strict mode, no any types
- **Tailwind CSS**: Utility-first styling
- **shadcn/ui**: Component library
- **State**: Zustand for global, React Query for server

## File Conventions
```
app/
  (routes)/
    page.tsx          # Server Component by default
    layout.tsx        # Shared layout
    loading.tsx       # Loading UI
    error.tsx         # Error boundary
components/
  ui/                 # shadcn components
  features/           # Feature-specific
lib/
  utils.ts           # Utilities
  hooks/             # Custom hooks
```

## Patterns
- Server Components default, Client only for interactivity
- Colocate components with routes when specific
- Use `cn()` for conditional classes
- Proper error boundaries at route level
- Suspense for async operations

## Quality Checks
- [ ] TypeScript strict, no errors
- [ ] Accessibility (ARIA, keyboard)
- [ ] Loading and error states
- [ ] Mobile responsive
- [ ] Performance (no unnecessary re-renders)
