<script lang="ts">
  import { toastStore } from '$lib/stores/toasts.svelte';
  import ToastItem from './Toast.svelte';
</script>

{#if toastStore.toasts.length > 0}
  <div class="tc-container" aria-label="Notifications" role="region">
    {#each toastStore.toasts as toast (toast.id)}
      <ToastItem {toast} />
    {/each}
  </div>
{/if}

<style>
  .tc-container {
    position: fixed;
    bottom: 24px;
    right: 20px;
    z-index: 600;
    display: flex;
    flex-direction: column;
    gap: 8px;
    pointer-events: none;
    /* Stack newest at bottom — items render top-to-bottom in DOM order */
    align-items: flex-end;
  }
</style>
