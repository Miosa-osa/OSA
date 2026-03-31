<script lang="ts">
  interface Props {
    path: string;
    description?: string;
    contentPreview?: string;
  }

  let { path, description = '', contentPreview }: Props = $props();

  const filename = $derived(path.split('/').pop() || path);

  const ext = $derived(filename.split('.').pop()?.toLowerCase() || '');

  const icons: Record<string, string> = {
    ts: '📘', tsx: '📘', js: '📒', jsx: '📒',
    svelte: '🔶', ex: '💜', exs: '💜',
    go: '🔵', rs: '🦀', py: '🐍',
    md: '📝', json: '📋', css: '🎨',
  };

  const icon = $derived(icons[ext] || '📄');
</script>

<div class="file-perm">
  <div class="file-info">
    <span class="file-icon" aria-hidden="true">{icon}</span>
    <div class="file-details">
      <span class="file-name">{filename}</span>
      <span class="file-path">{path}</span>
    </div>
  </div>

  {#if description}
    <p class="file-desc">{description}</p>
  {/if}

  {#if contentPreview}
    <div class="preview-block">
      <div class="preview-label">Preview</div>
      <pre class="preview-code"><code>{contentPreview}</code></pre>
    </div>
  {/if}
</div>

<style>
  .file-perm {
    margin: 8px 0;
  }

  .file-info {
    display: flex;
    align-items: flex-start;
    gap: 8px;
    margin-bottom: 8px;
  }

  .file-icon {
    font-size: 1.25rem;
    flex-shrink: 0;
    margin-top: 1px;
  }

  .file-details {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }

  .file-name {
    font-size: 0.875rem;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.85);
  }

  .file-path {
    font-size: 0.75rem;
    font-family: 'SF Mono', monospace;
    color: rgba(255, 255, 255, 0.35);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .file-desc {
    font-size: 0.8125rem;
    color: rgba(255, 255, 255, 0.5);
    margin: 0 0 8px;
  }

  .preview-block {
    margin-top: 6px;
  }

  .preview-label {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.3);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin-bottom: 4px;
  }

  .preview-code {
    background: rgba(0, 0, 0, 0.3);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 6px;
    padding: 8px 10px;
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.6);
    overflow-x: auto;
    white-space: pre-wrap;
    max-height: 200px;
    overflow-y: auto;
    margin: 0;
  }
</style>
