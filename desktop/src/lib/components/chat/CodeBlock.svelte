<script lang="ts">
  import hljs from 'highlight.js';

  interface Props {
    language: string;
    code: string;
  }

  let { language, code }: Props = $props();

  let highlighted = $state('');
  let copied = $state(false);

  // Re-highlight whenever code or language changes (handles streaming updates)
  $effect(() => {
    const lang = hljs.getLanguage(language) ? language : 'plaintext';
    highlighted = hljs.highlight(code, { language: lang }).value;
  });

  async function copyCode() {
    try {
      await navigator.clipboard.writeText(code);
      copied = true;
      setTimeout(() => {
        copied = false;
      }, 2000);
    } catch {
      // Clipboard write failed — silently ignore (Tauri sandboxing may block)
    }
  }
</script>

<div class="code-block" role="region" aria-label="{language} code block">
  <div class="code-header">
    <span class="lang-badge">{language || 'text'}</span>
    <button
      class="copy-btn"
      onclick={copyCode}
      aria-label={copied ? 'Code copied to clipboard' : 'Copy code to clipboard'}
    >
      {copied ? 'Copied' : 'Copy'}
    </button>
  </div>
  <pre class="code-pre"><code class="code-body hljs">{@html highlighted}</code></pre>
</div>

<style>
  .code-block {
    border-radius: 10px;
    overflow: hidden;
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: rgba(0, 0, 0, 0.45);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
  }

  .code-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 6px 14px;
    background: rgba(255, 255, 255, 0.04);
    border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  }

  .lang-badge {
    font-size: 0.6875rem;
    font-weight: 500;
    letter-spacing: 0.06em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.35);
  }

  .copy-btn {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.4);
    background: none;
    border: none;
    cursor: pointer;
    padding: 2px 6px;
    border-radius: 4px;
    transition:
      color 0.15s,
      background 0.15s;
  }

  .copy-btn:hover {
    color: rgba(255, 255, 255, 0.8);
    background: rgba(255, 255, 255, 0.08);
  }

  .code-pre {
    margin: 0;
    padding: 14px 16px;
    overflow-x: auto;
    font-size: 0.8125rem;
    line-height: 1.6;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .code-body {
    background: transparent !important;
    font-family: 'JetBrains Mono', 'Fira Code', 'Cascadia Code', monospace;
    white-space: pre;
  }
</style>
