<script lang="ts">
  interface Props {
    description: string;
    role?: string;
    task?: string;
  }

  let { description, role, task }: Props = $props();

  const displayRole = $derived(role || extractRole(description));
  const displayTask = $derived(task || description);

  function extractRole(desc: string): string {
    const match = desc.match(/role[:\s]+["']?(\w[\w-]*)["']?/i);
    return match?.[1] || 'agent';
  }
</script>

<div class="delegate-perm">
  <div class="agent-info">
    <div class="agent-icon" aria-hidden="true">
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
        <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
        <circle cx="9" cy="7" r="4" />
        <path d="M23 21v-2a4 4 0 0 0-3-3.87" />
        <path d="M16 3.13a4 4 0 0 1 0 7.75" />
      </svg>
    </div>
    <div class="agent-details">
      <span class="agent-role">{displayRole}</span>
      <span class="agent-label">Sub-agent delegation</span>
    </div>
  </div>

  <div class="task-block">
    <div class="task-label">Task</div>
    <p class="task-desc">{displayTask}</p>
  </div>
</div>

<style>
  .delegate-perm {
    margin: 8px 0;
  }

  .agent-info {
    display: flex;
    align-items: center;
    gap: 10px;
    margin-bottom: 10px;
  }

  .agent-icon {
    width: 36px;
    height: 36px;
    border-radius: 8px;
    background: rgba(6, 182, 212, 0.1);
    border: 1px solid rgba(6, 182, 212, 0.2);
    display: flex;
    align-items: center;
    justify-content: center;
    color: rgba(6, 182, 212, 0.7);
    flex-shrink: 0;
  }

  .agent-details {
    display: flex;
    flex-direction: column;
  }

  .agent-role {
    font-size: 0.875rem;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.85);
  }

  .agent-label {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.3);
  }

  .task-block {
    margin-top: 4px;
  }

  .task-label {
    font-size: 0.6875rem;
    color: rgba(255, 255, 255, 0.3);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin-bottom: 4px;
  }

  .task-desc {
    font-size: 0.8125rem;
    color: rgba(255, 255, 255, 0.6);
    line-height: 1.5;
    margin: 0;
    background: rgba(0, 0, 0, 0.15);
    border-radius: 6px;
    padding: 8px 10px;
  }
</style>
