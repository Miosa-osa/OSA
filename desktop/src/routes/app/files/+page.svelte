<script lang="ts">
  import FileTree from '$lib/components/workspace/FileTree.svelte';
  import PageShell from '$lib/components/layout/PageShell.svelte';
  import { BASE_URL, API_PREFIX } from '$lib/api/client';

  let selectedFile = $state<string | null>(null);
  let fileContent = $state<string | null>(null);
  let loadingContent = $state(false);

  async function handleFileSelect(path: string) {
    selectedFile = path;
    loadingContent = true;
    try {
      const res = await fetch(
        `${BASE_URL}${API_PREFIX}/workspace/read?path=${encodeURIComponent(path)}`
      );
      if (res.ok) {
        const data = await res.json();
        fileContent = data.content ?? null;
      } else {
        fileContent = null;
      }
    } catch {
      fileContent = null;
    } finally {
      loadingContent = false;
    }
  }
</script>

<PageShell title="Files" description="Browse workspace files">
  <div class="files-layout">
    <div class="files-tree">
      <FileTree onFileSelect={handleFileSelect} />
    </div>
    <div class="files-preview">
      {#if selectedFile}
        <div class="preview-header">
          <span class="preview-path">{selectedFile}</span>
        </div>
        {#if loadingContent}
          <div class="preview-loading">Loading...</div>
        {:else if fileContent !== null}
          <pre class="preview-code"><code>{fileContent}</code></pre>
        {:else}
          <div class="preview-empty">Unable to read file</div>
        {/if}
      {:else}
        <div class="preview-empty">Select a file to preview</div>
      {/if}
    </div>
  </div>
</PageShell>

<style>
  .files-layout {
    display: flex;
    height: 100%;
    gap: 1px;
    background: rgba(255, 255, 255, 0.04);
  }

  .files-tree {
    width: 280px;
    flex-shrink: 0;
    overflow-y: auto;
    background: rgba(0, 0, 0, 0.2);
    border-right: 1px solid rgba(255, 255, 255, 0.06);
  }

  .files-preview {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    background: rgba(0, 0, 0, 0.3);
  }

  .preview-header {
    padding: 8px 14px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
    flex-shrink: 0;
  }

  .preview-path {
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.75rem;
    color: rgba(255, 255, 255, 0.5);
  }

  .preview-code {
    flex: 1;
    margin: 0;
    padding: 12px 16px;
    font-family: 'SF Mono', 'Fira Code', monospace;
    font-size: 0.8125rem;
    line-height: 1.6;
    color: rgba(255, 255, 255, 0.75);
    overflow: auto;
    white-space: pre-wrap;
    word-break: break-all;
  }

  .preview-empty,
  .preview-loading {
    display: flex;
    align-items: center;
    justify-content: center;
    flex: 1;
    color: rgba(255, 255, 255, 0.2);
    font-size: 0.875rem;
  }
</style>
