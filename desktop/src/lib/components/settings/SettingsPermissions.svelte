<script lang="ts">
  import { permissionStore } from '$lib/stores/permissions.svelte';

  let yoloMode      = $state(permissionStore.yolo);
  let alwaysAllowed = $state<string[]>([]);
  let permTier      = $state<'full' | 'workspace' | 'readonly'>('full');

  function toggleYolo() {
    yoloMode = !yoloMode;
    if (yoloMode) {
      permissionStore.enableYolo();
    } else {
      permissionStore.disableYolo();
    }
  }

  function removeAlwaysAllowed(tool: string) {
    alwaysAllowed = alwaysAllowed.filter((t) => t !== tool);
  }
</script>

<section class="spm-section">
  <h2 class="spm-section-title">Permissions</h2>
  <p class="spm-section-desc">Control what the agent can do without asking.</p>

  <div class="spm-settings-group">
    <!-- YOLO mode -->
    <div class="spm-settings-item">
      <div class="spm-item-meta">
        <span class="spm-item-label">YOLO mode</span>
        <span class="spm-item-hint">Auto-approve all tool calls. No confirmation dialogs.</span>
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={yoloMode}
        aria-label="Toggle YOLO mode"
        class="spm-toggle"
        class:spm-toggle--on={yoloMode}
        onclick={toggleYolo}
      >
        <span class="spm-toggle-knob"></span>
      </button>
    </div>

    <div class="spm-item-divider"></div>

    <!-- Permission tier -->
    <div class="spm-settings-item spm-settings-item--col">
      <div class="spm-item-meta">
        <span class="spm-item-label">Permission tier</span>
        <span class="spm-item-hint">Default scope for new tool approvals.</span>
      </div>
      <div class="spm-tier-group">
        <label class="spm-tier-card" class:spm-tier-card--selected={permTier === 'full'}>
          <input type="radio" name="perm-tier" value="full" bind:group={permTier} class="spm-sr-only" />
          <span class="spm-tier-name">Full</span>
          <span class="spm-tier-desc">All tools enabled</span>
        </label>
        <label class="spm-tier-card" class:spm-tier-card--selected={permTier === 'workspace'}>
          <input type="radio" name="perm-tier" value="workspace" bind:group={permTier} class="spm-sr-only" />
          <span class="spm-tier-name">Workspace</span>
          <span class="spm-tier-desc">Working directory only</span>
        </label>
        <label class="spm-tier-card" class:spm-tier-card--selected={permTier === 'readonly'}>
          <input type="radio" name="perm-tier" value="readonly" bind:group={permTier} class="spm-sr-only" />
          <span class="spm-tier-name">Read-only</span>
          <span class="spm-tier-desc">No write operations</span>
        </label>
      </div>
    </div>
  </div>

  <!-- Always-allowed tools -->
  <div class="spm-field-label-row" style="margin-top: 24px;">
    <span class="spm-field-label-text">Always allowed tools</span>
  </div>
  <div class="spm-always-list">
    {#if alwaysAllowed.length === 0}
      <p class="spm-empty-hint">No tools granted permanent access this session.</p>
    {:else}
      {#each alwaysAllowed as tool (tool)}
        <div class="spm-always-item">
          <span class="spm-always-tool">{tool}</span>
          <button
            type="button"
            class="spm-btn-remove"
            aria-label="Remove {tool} from always allowed"
            onclick={() => removeAlwaysAllowed(tool)}
          >
            <svg width="12" height="12" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>
          </button>
        </div>
      {/each}
    {/if}
  </div>
</section>

<style>
  .spm-section { max-width: 560px; }

  .spm-section-title {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    margin: 0 0 4px;
  }

  .spm-section-desc { font-size: 13px; color: var(--text-tertiary); margin: 0 0 24px; }
  .spm-settings-group { background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.07); border-radius: 12px; overflow: hidden; }
  .spm-settings-item { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 13px 16px; min-height: 52px; }
  .spm-settings-item--col { flex-direction: column; align-items: flex-start; gap: 0; }
  .spm-item-divider { height: 1px; background: rgba(255,255,255,0.06); }
  .spm-item-meta { display: flex; flex-direction: column; gap: 2px; flex-shrink: 0; }
  .spm-item-label { font-size: 14px; color: rgba(255,255,255,0.88); font-weight: 450; white-space: nowrap; }
  .spm-item-hint { font-size: 11.5px; color: var(--text-tertiary); }

  /* Toggle switch */
  .spm-toggle { position: relative; width: 44px; height: 24px; flex-shrink: 0; background: rgba(255,255,255,0.1); border: 1px solid rgba(255,255,255,0.12); border-radius: 9999px; cursor: pointer; transition: background 0.2s ease, border-color 0.2s ease; padding: 0; outline: none; }
  .spm-toggle--on { background: rgba(59,130,246,0.55); border-color: rgba(59,130,246,0.4); }
  .spm-toggle:focus-visible { outline: 2px solid rgba(255,255,255,0.35); outline-offset: 2px; }
  .spm-toggle-knob { position: absolute; top: 3px; left: 3px; width: 16px; height: 16px; background: rgba(255,255,255,0.85); border-radius: 9999px; transition: transform 0.2s cubic-bezier(0.4,0,0.2,1), background 0.2s ease; box-shadow: 0 1px 3px rgba(0,0,0,0.35); }
  .spm-toggle--on .spm-toggle-knob { transform: translateX(20px); background: #fff; }

  /* Permission tier */
  .spm-tier-group { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
  .spm-tier-card { display: block; cursor: pointer; border-radius: 9px; border: 1px solid rgba(255,255,255,0.07); background: rgba(255,255,255,0.03); padding: 10px 14px; transition: border-color 0.15s ease, background 0.15s ease; min-width: 110px; }
  .spm-tier-card:hover { border-color: rgba(255,255,255,0.13); background: rgba(255,255,255,0.05); }
  .spm-tier-card--selected { border-color: rgba(59,130,246,0.45); background: rgba(59,130,246,0.08); }
  .spm-tier-name { display: block; font-size: 13px; font-weight: 500; color: rgba(255,255,255,0.88); margin-bottom: 2px; }
  .spm-tier-desc { display: block; font-size: 11px; color: var(--text-tertiary); }

  /* Always-allowed list */
  .spm-field-label-row { margin-bottom: 8px; }
  .spm-field-label-text { font-size: 12px; font-weight: 500; color: rgba(255,255,255,0.4); text-transform: uppercase; letter-spacing: 0.06em; }
  .spm-always-list { display: flex; flex-direction: column; gap: 6px; }
  .spm-always-item { display: flex; align-items: center; justify-content: space-between; padding: 8px 12px; background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.06); border-radius: 8px; }
  .spm-always-tool { font-size: 12.5px; font-family: var(--font-mono); color: rgba(255,255,255,0.75); }
  .spm-empty-hint { font-size: 13px; color: var(--text-tertiary); padding: 12px 0; }

  .spm-btn-remove { background: none; border: none; color: var(--text-tertiary); cursor: pointer; padding: 3px; display: flex; align-items: center; justify-content: center; border-radius: 4px; transition: color 0.13s ease, background 0.13s ease; }
  .spm-btn-remove:hover { color: var(--accent-error); background: rgba(239,68,68,0.08); }
  .spm-btn-remove:focus-visible { outline: 2px solid rgba(239,68,68,0.4); }
  .spm-sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border-width: 0; }
  @media (prefers-reduced-motion: reduce) { .spm-toggle-knob { transition: none; } .spm-toggle { transition: none; } }
</style>
