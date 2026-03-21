<script lang="ts">
  import type { IssueComment } from '$lib/stores/issues.svelte';

  interface Props {
    comments: IssueComment[];
    onAddComment: (content: string) => Promise<void>;
  }

  let { comments, onAddComment }: Props = $props();

  let draftText = $state('');
  let submitting = $state(false);

  function timeAgo(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const mins = Math.floor(diff / 60_000);
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    return `${Math.floor(hrs / 24)}d ago`;
  }

  function initials(name: string): string {
    return name
      .split(/[\s_-]/)
      .map((w) => w[0] ?? '')
      .slice(0, 2)
      .join('')
      .toUpperCase();
  }

  async function handleSubmit() {
    const content = draftText.trim();
    if (!content || submitting) return;
    submitting = true;
    try {
      await onAddComment(content);
      draftText = '';
    } finally {
      submitting = false;
    }
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void handleSubmit();
    }
  }
</script>

<section class="ct-section" aria-label="Comments">
  <h3 class="ct-heading">Comments</h3>

  {#if comments.length === 0}
    <p class="ct-empty">No comments yet.</p>
  {:else}
    <ol class="ct-list">
      {#each comments as comment (comment.id)}
        <li class="ct-item">
          <div
            class="ct-avatar"
            aria-hidden="true"
            title={comment.author}
          >
            {initials(comment.author)}
          </div>
          <div class="ct-body">
            <div class="ct-meta">
              <span class="ct-author">{comment.author}</span>
              <time
                class="ct-time"
                datetime={comment.created_at}
                title={new Date(comment.created_at).toLocaleString()}
              >
                {timeAgo(comment.created_at)}
              </time>
            </div>
            <p class="ct-content">{comment.content}</p>
          </div>
        </li>
      {/each}
    </ol>
  {/if}

  <!-- Add comment -->
  <div class="ct-compose" role="form" aria-label="Add a comment">
    <textarea
      class="ct-textarea"
      placeholder="Add a comment… (Enter to submit, Shift+Enter for newline)"
      bind:value={draftText}
      onkeydown={handleKeyDown}
      aria-label="Comment text"
      rows={2}
      disabled={submitting}
    ></textarea>
    <div class="ct-compose-footer">
      <span class="ct-hint">Enter to submit · Shift+Enter for newline</span>
      <button
        class="ct-submit"
        onclick={handleSubmit}
        disabled={!draftText.trim() || submitting}
        aria-label="Submit comment"
      >
        {submitting ? 'Posting…' : 'Comment'}
      </button>
    </div>
  </div>
</section>

<style>
  .ct-section {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .ct-heading {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }

  .ct-empty {
    font-size: 0.8125rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    padding: 8px 0;
  }

  .ct-list {
    display: flex;
    flex-direction: column;
    gap: 14px;
    list-style: none;
    padding: 0;
    margin: 0;
  }

  .ct-item {
    display: flex;
    gap: 10px;
    align-items: flex-start;
  }

  .ct-avatar {
    width: 26px;
    height: 26px;
    border-radius: 50%;
    background: rgba(59, 130, 246, 0.15);
    border: 1px solid rgba(59, 130, 246, 0.2);
    color: rgba(59, 130, 246, 0.8);
    font-size: 0.5rem;
    font-weight: 700;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    margin-top: 1px;
  }

  .ct-body {
    flex: 1;
    min-width: 0;
  }

  .ct-meta {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-bottom: 4px;
  }

  .ct-author {
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
  }

  .ct-time {
    font-size: 0.6875rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
    font-variant-numeric: tabular-nums;
  }

  .ct-content {
    font-size: 0.8125rem;
    color: var(--text-secondary, rgba(255, 255, 255, 0.6));
    line-height: 1.55;
    white-space: pre-wrap;
    word-break: break-word;
  }

  /* Compose area */
  .ct-compose {
    display: flex;
    flex-direction: column;
    gap: 6px;
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-sm, 6px);
    overflow: hidden;
    background: rgba(255, 255, 255, 0.03);
    transition: border-color 0.15s;
  }

  .ct-compose:focus-within {
    border-color: rgba(255, 255, 255, 0.15);
  }

  .ct-textarea {
    background: transparent;
    border: none;
    outline: none;
    resize: none;
    padding: 10px 12px 6px;
    font-size: 0.8125rem;
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
    font-family: inherit;
    line-height: 1.5;
    width: 100%;
  }

  .ct-textarea::placeholder {
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
  }

  .ct-textarea:disabled {
    opacity: 0.5;
  }

  .ct-compose-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 4px 12px 8px;
  }

  .ct-hint {
    font-size: 0.625rem;
    color: var(--text-muted, rgba(255, 255, 255, 0.25));
  }

  .ct-submit {
    padding: 4px 14px;
    border-radius: var(--radius-sm, 6px);
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.1);
    color: var(--text-primary, rgba(255, 255, 255, 0.88));
    font-size: 0.75rem;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.12s, opacity 0.12s;
  }

  .ct-submit:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.12);
  }

  .ct-submit:disabled {
    opacity: 0.35;
    cursor: not-allowed;
  }
</style>
