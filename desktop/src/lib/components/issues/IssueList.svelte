<script lang="ts">
  import type { Issue, IssueStatus } from '$lib/stores/issues.svelte';
  import IssueCard from './IssueCard.svelte';

  interface Props {
    issues: Issue[];
    onSelect: (issue: Issue) => void;
    onStatusChange: (id: string, status: IssueStatus) => void;
  }

  let { issues, onSelect, onStatusChange }: Props = $props();
</script>

<div class="il-list" role="list" aria-label="Issues">
  {#if issues.length === 0}
    <div class="il-empty" role="status" aria-label="No issues">
      <div class="il-empty-icon" aria-hidden="true">
        <svg width="40" height="40" viewBox="0 0 40 40" fill="none">
          <circle cx="20" cy="20" r="14" stroke="currentColor" stroke-width="1.5" opacity="0.3" />
          <circle cx="20" cy="20" r="4" fill="currentColor" opacity="0.25" />
        </svg>
      </div>
      <p class="il-empty-title">No issues found</p>
      <p class="il-empty-sub">Try adjusting your filters or create a new issue.</p>
    </div>
  {:else}
    <!-- Column header row -->
    <div class="il-header" aria-hidden="true">
      <span class="il-hcol il-hcol--status"></span>
      <span class="il-hcol il-hcol--title">Title</span>
      <span class="il-hcol il-hcol--labels">Labels</span>
      <span class="il-hcol il-hcol--priority">Priority</span>
      <span class="il-hcol il-hcol--assignee">Assignee</span>
      <span class="il-hcol il-hcol--age">Age</span>
    </div>

    {#each issues as issue (issue.id)}
      <div role="listitem">
        <IssueCard {issue} {onSelect} {onStatusChange} />
      </div>
    {/each}
  {/if}
</div>

<style>
  .il-list {
    display: flex;
    flex-direction: column;
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md, 8px);
    overflow: hidden;
    background: rgba(255, 255, 255, 0.015);
  }

  /* Column header */
  .il-header {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 7px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    background: rgba(255, 255, 255, 0.02);
  }

  .il-hcol {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-muted, rgba(255, 255, 255, 0.28));
  }

  .il-hcol--status { width: 20px; flex-shrink: 0; }
  .il-hcol--title { flex: 1; min-width: 0; }
  .il-hcol--labels { width: 140px; flex-shrink: 0; }
  .il-hcol--priority { width: 64px; flex-shrink: 0; }
  .il-hcol--assignee { width: 22px; flex-shrink: 0; }
  .il-hcol--age { width: 52px; flex-shrink: 0; text-align: right; }

  /* Empty state */
  .il-empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 56px 32px;
    gap: 8px;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
    text-align: center;
  }

  .il-empty-icon {
    color: rgba(255, 255, 255, 0.12);
    margin-bottom: 4px;
  }

  .il-empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary, rgba(255, 255, 255, 0.55));
  }

  .il-empty-sub {
    font-size: 0.8125rem;
    color: var(--text-tertiary, rgba(255, 255, 255, 0.4));
    max-width: 280px;
    line-height: 1.55;
  }
</style>
