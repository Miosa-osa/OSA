<script lang="ts">
  interface Props {
    command: string;
    paths?: string[];
  }

  let { command, paths = [] }: Props = $props();

  const DESTRUCTIVE_PATTERNS = [
    /\brm\s+-[rf]/,
    /\bdrop\s+/i,
    /\bdelete\s+/i,
    /\bkill\s+-9/,
    /\bgit\s+reset\s+--hard/,
    /\bgit\s+push\s+--force/,
    /\btruncate\s+/i,
    /\bformat\s+/i,
  ];

  const isDestructive = $derived(
    DESTRUCTIVE_PATTERNS.some(p => p.test(command))
  );

  const cwd = $derived(
    paths.length > 0 ? paths[0] : null
  );
</script>

<div class="shell-perm" class:shell-perm--destructive={isDestructive}>
  {#if isDestructive}
    <div class="warning-banner" role="alert">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
        <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z" />
        <line x1="12" y1="9" x2="12" y2="13" />
        <line x1="12" y1="17" x2="12.01" y2="17" />
      </svg>
      <span>Potentially destructive command</span>
    </div>
  {/if}

  <div class="command-block">
    <div class="command-label">Command</div>
    <pre class="command-code"><code>{command}</code></pre>
  </div>

  {#if cwd}
    <div class="cwd">
      <span class="cwd-label">Directory:</span>
      <span class="cwd-path">{cwd}</span>
    </div>
  {/if}
</div>

<style>
  .shell-perm {
    margin: 8px 0;
  }

  .shell-perm--destructive {
    border-left: 2px solid rgba(239, 68, 68, 0.5);
    padding-left: 8px;
  }

  .warning-banner {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    margin-bottom: 8px;
    background: rgba(239, 68, 68, 0.08);
    border: 1px solid rgba(239, 68, 68, 0.2);
    border-radius: 6px;
    color: #f87171;
    font-size: 0.75rem;
    font-weight: 500;
  }

  .command-block {
    margin-bottom: 6px;
  }

  .command-label {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.35);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin-bottom: 4px;
  }

  .command-code {
    background: rgba(0, 0, 0, 0.3);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 6px;
    padding: 8px 10px;
    font-family: 'SF Mono', 'Fira Code', 'Cascadia Code', monospace;
    font-size: 0.8125rem;
    color: rgba(255, 255, 255, 0.85);
    overflow-x: auto;
    white-space: pre-wrap;
    word-break: break-all;
    margin: 0;
  }

  .cwd {
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.3);
  }

  .cwd-label {
    color: rgba(255, 255, 255, 0.25);
  }

  .cwd-path {
    font-family: 'SF Mono', monospace;
    color: rgba(255, 255, 255, 0.45);
  }
</style>
