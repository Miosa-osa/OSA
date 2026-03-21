<script lang="ts">
  interface Props {
    firstTask: string;
    onNext: (task: string) => void;
    onBack: () => void;
  }

  let { firstTask = $bindable(), onNext, onBack }: Props = $props();

  const EXAMPLES = [
    'Review and improve this codebase',
    'Set up CI/CD pipeline',
    'Write tests for untested modules',
    'Create project documentation',
  ] as const;

  function selectExample(example: string) {
    firstTask = example;
  }

  function handleContinue() {
    onNext(firstTask.trim());
  }

  function handleSkip() {
    onNext('');
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') onBack();
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="sft-root">
  <div class="sft-heading">
    <h1 class="sft-title">Give your agent a task</h1>
    <p class="sft-sub">What would you like your agent to work on first? You can always change this later.</p>
  </div>

  <div class="sft-field">
    <label for="sft-task" class="sft-label">First task</label>
    <textarea
      id="sft-task"
      class="sft-textarea"
      placeholder="What would you like your agent to work on?"
      bind:value={firstTask}
      rows="4"
      aria-describedby="sft-hint"
    ></textarea>
    <p id="sft-hint" class="sft-hint">Be as specific or as broad as you like.</p>
  </div>

  <div class="sft-examples" aria-label="Task suggestions">
    <p class="sft-examples-label">Suggestions</p>
    <div class="sft-chips">
      {#each EXAMPLES as example}
        <button
          type="button"
          class="sft-chip"
          class:sft-chip--active={firstTask === example}
          onclick={() => selectExample(example)}
          aria-pressed={firstTask === example}
        >
          {example}
        </button>
      {/each}
    </div>
  </div>

  <div class="sft-actions">
    <button class="ob-btn ob-btn--ghost" onclick={onBack} aria-label="Back to agent configuration">
      Back
    </button>
    <div class="sft-actions-right">
      <button class="ob-btn ob-btn--ghost" onclick={handleSkip} aria-label="Skip, set up a task later">
        Skip for now
      </button>
      <button
        class="ob-btn ob-btn--primary"
        onclick={handleContinue}
        aria-label="Continue to launch"
      >
        Continue
        <svg width="14" height="14" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
        </svg>
      </button>
    </div>
  </div>
</div>

<style>
  .sft-root {
    display: flex;
    flex-direction: column;
    gap: 18px;
    height: 100%;
  }

  .sft-title {
    font-size: 22px;
    font-weight: 800;
    color: #ffffff;
    letter-spacing: -0.03em;
    margin: 0 0 4px;
  }

  .sft-sub {
    font-size: 13px;
    color: #a0a0a0;
    margin: 0;
    line-height: 1.5;
  }

  .sft-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .sft-label {
    font-size: 12px;
    font-weight: 500;
    color: #a0a0a0;
    letter-spacing: 0.02em;
  }

  .sft-textarea {
    width: 100%;
    padding: 11px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 10px;
    color: #ffffff;
    font-size: 13px;
    outline: none;
    resize: none;
    transition: border-color 0.15s ease, background 0.15s ease;
    box-sizing: border-box;
    font-family: inherit;
    line-height: 1.5;
  }

  .sft-textarea::placeholder {
    color: rgba(255, 255, 255, 0.2);
  }

  .sft-textarea:focus {
    border-color: rgba(255, 255, 255, 0.25);
    background: rgba(255, 255, 255, 0.06);
  }

  .sft-hint {
    font-size: 11px;
    color: #555555;
    margin: 0;
  }

  .sft-examples {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .sft-examples-label {
    font-size: 11px;
    font-weight: 500;
    color: #555555;
    margin: 0;
    letter-spacing: 0.04em;
    text-transform: uppercase;
  }

  .sft-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }

  .sft-chip {
    display: inline-flex;
    align-items: center;
    padding: 5px 11px;
    border-radius: 9999px;
    font-size: 12px;
    font-weight: 400;
    color: #a0a0a0;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    cursor: pointer;
    transition: background 0.15s ease, color 0.15s ease, border-color 0.15s ease;
    white-space: nowrap;
  }

  .sft-chip:hover {
    background: rgba(255, 255, 255, 0.07);
    border-color: rgba(255, 255, 255, 0.15);
    color: #e0e0e0;
  }

  .sft-chip:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    outline-offset: 2px;
  }

  .sft-chip--active {
    background: rgba(255, 255, 255, 0.08);
    border-color: rgba(255, 255, 255, 0.22);
    color: #ffffff;
  }

  .sft-actions {
    margin-top: auto;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .sft-actions-right {
    display: flex;
    align-items: center;
    gap: 8px;
  }
</style>
