<script lang="ts">
  import type { MemoryCategory } from '$lib/stores/memory.svelte';

  // ── Props ────────────────────────────────────────────────────────────────────

  interface Props {
    onSubmit: (entry: { key: string; value: string; category: MemoryCategory; tags: string[] }) => Promise<void>;
    onCancel: () => void;
  }

  let { onSubmit, onCancel }: Props = $props();

  // ── Form state ───────────────────────────────────────────────────────────────

  let key = $state('');
  let value = $state('');
  let category = $state<MemoryCategory>('fact');
  let tags = $state('');
  let submitting = $state(false);

  let isValid = $derived(key.trim().length > 0 && value.trim().length > 0);

  // ── Handlers ─────────────────────────────────────────────────────────────────

  async function handleSubmit() {
    if (!isValid || submitting) return;
    submitting = true;
    const parsedTags = tags.split(',').map((t) => t.trim()).filter(Boolean);
    await onSubmit({ key: key.trim(), value: value.trim(), category, tags: parsedTags });
    // Reset
    key = '';
    value = '';
    category = 'fact';
    tags = '';
    submitting = false;
  }

  function handleCancel() {
    key = '';
    value = '';
    category = 'fact';
    tags = '';
    onCancel();
  }
</script>

<div class="mf-wrap" id="add-memory-form" role="form" aria-label="Add new memory entry">
  <div class="mf-form">
    <div class="mf-row">
      <div class="mf-field mf-field--key">
        <label class="mf-label" for="mf-key">Key</label>
        <input
          id="mf-key"
          class="glass-input mf-input"
          type="text"
          bind:value={key}
          placeholder="e.g. user.preferred_language"
          spellcheck="false"
          aria-label="Memory key"
        />
      </div>
      <div class="mf-field mf-field--category">
        <label class="mf-label" for="mf-category">Category</label>
        <div class="mf-select-wrapper">
          <select
            id="mf-category"
            class="glass-input mf-select"
            bind:value={category}
            aria-label="Memory category"
          >
            <option value="fact">Fact</option>
            <option value="preference">Preference</option>
            <option value="context">Context</option>
            <option value="instruction">Instruction</option>
            <option value="other">Other</option>
          </select>
          <svg class="mf-select-chevron" width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">
            <polyline points="2,3.5 5.5,7 9,3.5"/>
          </svg>
        </div>
      </div>
    </div>

    <div class="mf-field">
      <label class="mf-label" for="mf-value">Value</label>
      <textarea
        id="mf-value"
        class="glass-input mf-textarea"
        bind:value={value}
        placeholder="Memory value..."
        rows="3"
        spellcheck="false"
        aria-label="Memory value"
      ></textarea>
    </div>

    <div class="mf-field">
      <label class="mf-label" for="mf-tags">
        Tags <span class="mf-label-hint">(comma-separated, optional)</span>
      </label>
      <input
        id="mf-tags"
        class="glass-input mf-input"
        type="text"
        bind:value={tags}
        placeholder="e.g. dev, languages"
        spellcheck="false"
        aria-label="Memory tags, comma separated, optional"
      />
    </div>

    <div class="mf-actions">
      <button
        class="mf-btn mf-btn--submit"
        onclick={handleSubmit}
        disabled={submitting || !isValid}
        aria-label="Save new memory entry"
      >
        {submitting ? 'Saving...' : 'Save Memory'}
      </button>
      <button
        class="mf-btn mf-btn--cancel"
        onclick={handleCancel}
        aria-label="Cancel adding memory"
      >
        Cancel
      </button>
    </div>
  </div>
</div>

<style>
  .mf-wrap {
    padding: 0 24px;
    flex-shrink: 0;
  }

  .mf-form {
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    margin-top: 16px;
  }

  .mf-row {
    display: grid;
    grid-template-columns: 1fr 160px;
    gap: 10px;
  }

  .mf-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .mf-label {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.07em;
    color: var(--text-tertiary);
  }

  .mf-label-hint {
    text-transform: none;
    letter-spacing: 0;
    font-weight: 400;
    color: var(--text-muted);
  }

  .mf-input {
    font-size: 0.8125rem;
    padding: 8px 11px;
  }

  .mf-textarea {
    font-size: 0.8125rem;
    padding: 8px 11px;
    resize: vertical;
    min-height: 64px;
    line-height: 1.5;
  }

  .mf-select-wrapper {
    position: relative;
  }

  .mf-select {
    appearance: none;
    -webkit-appearance: none;
    font-size: 0.8125rem;
    padding: 8px 28px 8px 11px;
    cursor: pointer;
    width: 100%;
  }

  .mf-select option {
    background: #1e1e1e;
    color: #fff;
  }

  .mf-select-chevron {
    position: absolute;
    right: 9px;
    top: 50%;
    transform: translateY(-50%);
    pointer-events: none;
    color: var(--text-tertiary);
  }

  .mf-actions {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .mf-btn {
    padding: 8px 16px;
    border-radius: var(--radius-md);
    font-size: 0.8125rem;
    font-weight: 500;
    border: 1px solid transparent;
    transition: background 0.15s, border-color 0.15s, opacity 0.15s;
  }

  .mf-btn--submit {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.16);
    color: var(--text-primary);
  }

  .mf-btn--submit:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.15);
    border-color: rgba(255, 255, 255, 0.25);
  }

  .mf-btn--submit:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }

  .mf-btn--cancel {
    background: none;
    border-color: transparent;
    color: var(--text-tertiary);
  }

  .mf-btn--cancel:hover {
    color: var(--text-secondary);
    background: rgba(255, 255, 255, 0.04);
  }
</style>
