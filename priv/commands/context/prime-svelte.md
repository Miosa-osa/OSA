---
name: prime-svelte
description: Load Svelte/SvelteKit development context
---

# Prime: Svelte/SvelteKit Development

## Tech Stack
- **Svelte 5**: Runes ($state, $derived, $effect)
- **SvelteKit**: File-based routing, load functions
- **TypeScript**: Full type safety
- **Tailwind CSS**: Styling

## File Conventions
```
src/
  routes/
    +page.svelte      # Page component
    +page.ts          # Universal load
    +page.server.ts   # Server-only load/actions
    +layout.svelte    # Layout
    +error.svelte     # Error page
  lib/
    components/       # Reusable components
    stores/           # Svelte stores
    server/           # Server-only code
```

## Svelte 5 Patterns
```svelte
<script lang="ts">
  let count = $state(0);
  let doubled = $derived(count * 2);
  
  $effect(() => {
    console.log('Count changed:', count);
  });
</script>
```

## SvelteKit Patterns
- Use +page.server.ts for sensitive data
- Form actions for mutations
- Load functions for data fetching
- Proper error handling with +error.svelte
