<script lang="ts">
  import { browser } from '$app/environment';
  import { goto } from '$app/navigation';
  import { onMount } from 'svelte';
  import { fade } from 'svelte/transition';
  import Sidebar from '$lib/components/layout/Sidebar.svelte';
  import ConnectionStatusBar from '$lib/components/layout/ConnectionStatusBar.svelte';
  import { connectionStore } from '$lib/stores/connection.svelte';
  // TitleBar removed — using native decorations
  import PermissionOverlay from '$lib/components/permissions/PermissionOverlay.svelte';
  import SurveyDialog from '$lib/components/survey/SurveyDialog.svelte';
  import TaskCard from '$lib/components/tasks/TaskCard.svelte';
  import CommandPalette from '$lib/components/palette/CommandPalette.svelte';
  import ToastContainer from '$lib/components/layout/ToastContainer.svelte';
  import { restartBackend } from '$lib/utils/backend';
  import { settingsStore } from '$lib/stores/settingsStore';
  import { permissionStore } from '$lib/stores/permissions.svelte';
  import { surveyStore } from '$lib/stores/survey.svelte';
  import { taskStore } from '$lib/stores/tasks.svelte';
  import { chatStore } from '$lib/stores/chat.svelte';
  import { paletteStore } from '$lib/stores/palette.svelte';
  import { agentsStore } from '$lib/stores/agents.svelte';
  import { projectsStore } from '$lib/stores/projects.svelte';
  import { themeStore } from '$lib/stores/theme.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import type { StreamEvent } from '$lib/api/types';
  import type { Survey } from '$lib/stores/survey.svelte';
  import { isOnboardingComplete } from '$lib/onboarding/store';
  import { isTauri } from '$lib/utils/platform';

  let { children } = $props();

  // Initialize theme on mount — themeStore constructor handles DOM application
  // We reference it here to ensure it's created in the browser context
  $effect(() => {
    void themeStore.resolved; // subscribe to theme changes
  });

  // Sidebar collapsed state — persisted to localStorage
  let sidebarCollapsed = $state(false);

  $effect(() => {
    if (!browser) return;
    const stored = localStorage.getItem('osa-sidebar-collapsed');
    if (stored !== null) sidebarCollapsed = stored === 'true';
  });

  function toggleSidebar() {
    sidebarCollapsed = !sidebarCollapsed;
    if (browser) {
      localStorage.setItem('osa-sidebar-collapsed', String(sidebarCollapsed));
    }
  }

  // Nav routes mapped to keyboard shortcuts ⌘1–⌘0
  const NAV_ROUTES = ['/app', '/app/chat', '/app/agents', '/app/models', '/app/terminal', '/app/settings', '/app/connectors', '/app/activity', '/app/usage', '/app/tasks'];

  // ── SSE Event Dispatcher ────────────────────────────────────────────────────
  //
  // Routes streaming events from chatStore to the permission, survey, and task
  // stores. The chatStore already owns the SSE connection — we intercept via
  // $effect on the streaming state instead of opening a second connection.
  //
  // For tool_call events with phase "awaiting_permission", the permission store
  // needs to post a decision back to the backend. We use a fire-and-forget
  // approach: the store's promise resolves when the user decides, then we POST
  // the decision to the backend via the chat session endpoint.

  function dispatchStreamEvent(event: StreamEvent): void {
    switch (event.type) {
      case 'tool_call': {
        if (event.phase === 'awaiting_permission') {
          const sessionId = chatStore.currentSession?.id;
          const toolUseId = event.tool_use_id;

          permissionStore.handleToolCallEvent(
            event.tool_name,
            event.description ?? `Run tool: ${event.tool_name}`,
            event.paths ?? [],
            (decision) => {
              // POST decision back to backend if we have a session
              if (!sessionId) return;
              const BASE = 'http://127.0.0.1:9089/api/v1';
              fetch(`${BASE}/sessions/${sessionId}/tool_calls/${toolUseId}/decision`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ decision }),
              }).catch(() => {
                // Non-fatal — backend may not support this endpoint yet
              });
            },
          );
        }
        break;
      }

      case 'system_event': {
        if (event.event === 'survey_shown') {
          const payload = event.payload as { survey?: Survey; session_id?: string } | undefined;
          if (payload?.survey) {
            surveyStore.showSurvey(payload.survey, payload.session_id).catch(() => {
              // Dismissed — not an error
            });
          }
        }

        // Task lifecycle events arrive as system_event subtypes
        if (event.event === 'task_created') {
          const payload = event.payload as { task_id?: string; text?: string } | undefined;
          if (payload?.task_id && payload.text) {
            taskStore.addTask(payload.task_id, payload.text);
          }
        }

        if (event.event === 'task_updated') {
          const payload = event.payload as { task_id?: string; status?: string } | undefined;
          if (payload?.task_id && payload.status) {
            taskStore.updateTask(
              payload.task_id,
              payload.status as import('$lib/stores/tasks.svelte').TaskStatus,
            );
          }
        }
        break;
      }

      case 'done':
        // Nothing needed at layout level — chatStore finalizes the message
        break;

      default:
        break;
    }
  }

  // Register with chatStore on mount — receives every raw SSE event.
  // Cleaned up automatically when the layout is destroyed.
  onMount(() => {
    // ── Onboarding gate ─────────────────────────────────────────────────────
    // Only runs inside Tauri — Tauri store APIs are unavailable in SSR/browser.
    // If onboarding has not been completed, redirect before loading the app.
    if (isTauri()) {
      void isOnboardingComplete().then((complete) => {
        if (!complete) {
          void goto('/onboarding');
        }
      });
    }

    void workspaceStore.fetchWorkspaces();
    const stopPolling = connectionStore.startPolling(10_000);
    chatStore.addStreamListener(dispatchStreamEvent);

    // Listen for osa:send-message events from Connectors page and other sources
    function handleOSASend(e: Event) {
      const detail = (e as CustomEvent).detail;
      if (detail?.message) {
        chatStore.sendMessage(detail.message);
        goto('/app/chat'); // Navigate to chat
      }
    }
    window.addEventListener('osa:send-message', handleOSASend);

    return () => {
      stopPolling();
      chatStore.removeStreamListener(dispatchStreamEvent);
      window.removeEventListener('osa:send-message', handleOSASend);
    };
  });

  // ── Command Palette — register builtins + search sources ─────────────────────

  onMount(() => {
    paletteStore.registerBuiltins(goto, {
      newSession: () => {
        void chatStore.createSession().then((session) => {
          void goto(`/app?session=${session.id}`);
        });
      },
      clearChat: () => {
        // Start a fresh session — the idiomatic "clear" in OSA
        void chatStore.createSession().then((session) => {
          void goto(`/app?session=${session.id}`);
        });
      },
      toggleYolo: () => {
        if (permissionStore.yolo) permissionStore.disableYolo();
        else permissionStore.enableYolo();
      },
      restartBackend: () => {
        restartBackend().catch(() => {});
      },
      newIssue: () => void goto('/app/issues?new=1'),
      newProject: () => void goto('/app/projects?new=1'),
    });

    paletteStore.registerSearchSources([
      {
        type: 'Agent',
        icon: 'agents',
        items: () =>
          agentsStore.agents.map((a) => ({
            id: a.id,
            name: a.name,
            description: a.task ?? a.status,
          })),
        action: (_item) => void goto(`/app/agents`),
      },
      {
        type: 'Task',
        icon: 'tasks',
        items: () =>
          taskStore.tasks.map((t) => ({
            id: t.id,
            name: t.text,
            description: t.status,
          })),
        action: (_item) => void goto('/app/tasks'),
      },
      {
        type: 'Project',
        icon: 'projects',
        items: () =>
          projectsStore.projects.map((p) => ({
            id: p.id,
            name: p.name,
            description: p.description ?? undefined,
          })),
        action: (_item) => void goto(`/app/projects`),
      },
    ]);
  });

  // ── Keyboard Shortcuts ───────────────────────────────────────────────────────

  onMount(() => {
    function handleKeyDown(e: KeyboardEvent) {
      const meta = e.metaKey || e.ctrlKey;

      // ⌘K — open command palette (checked before other meta shortcuts)
      if (meta && (e.key === 'k' || e.key === 'K')) {
        e.preventDefault();
        paletteStore.toggle();
        return;
      }

      if (!meta) return;

      // ⌘\ — toggle sidebar
      if (e.key === '\\') {
        e.preventDefault();
        toggleSidebar();
        return;
      }

      // ⌘, — settings
      if (e.key === ',') {
        e.preventDefault();
        goto('/app/settings');
        return;
      }

      // ⌘Y — toggle YOLO mode
      if (e.key === 'y' || e.key === 'Y') {
        e.preventDefault();
        if (permissionStore.yolo) {
          permissionStore.disableYolo();
        } else {
          permissionStore.enableYolo();
        }
        return;
      }

      // ⌘1–⌘0 — navigate to route by position
      const idx = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'].indexOf(e.key);
      if (idx !== -1) {
        e.preventDefault();
        goto(NAV_ROUTES[idx]);
      }
    }

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  });

  // Synthesize a sidebar user from settings agent_name when available.
  const user = $derived(
    $settingsStore.data?.agent_name
      ? { name: $settingsStore.data.agent_name, email: "" }
      : null,
  );

  // ── TaskCard: send question into the active chat session ─────────────────────

  function handleTaskAsk(question: string) {
    chatStore.sendMessage(question);
  }
</script>

<div class="app-shell">
  <!--
    TitleBar: transparent overlay for macOS drag region.
    pointer-events: none on the bar itself ensures clicks
    pass through to sidebar toggle and nav links below.
  -->
  <!-- TitleBar removed — native decorations handle window chrome now -->

  <!-- Icon sidebar -->
  <Sidebar
    bind:isCollapsed={sidebarCollapsed}
    onToggle={toggleSidebar}
    {user}
  />

  <!-- Main content -->
  <main class="main-content" id="main-content">
    {@render children()}

    <!-- TaskCard — floats above the input dock, bottom-center of chat area -->
    {#if taskStore.hasTasks}
      <div
        class="task-card-anchor"
        transition:fade={{ duration: 200 }}
      >
        <TaskCard tasks={taskStore.tasks} onAsk={handleTaskAsk} />
      </div>
    {/if}

    <ConnectionStatusBar />
  </main>
</div>

<!-- Global overlays — rendered outside the flex layout so z-index stacks correctly -->

<!-- Command palette (Cmd/Ctrl+K) -->
{#if paletteStore.isOpen}
  <CommandPalette />
{/if}

<!-- Permission request overlay (queued, shown one at a time) -->
<PermissionOverlay />

<!-- Survey dialog (queued, shown one at a time) -->
{#if surveyStore.activeSurvey}
  <SurveyDialog
    survey={surveyStore.activeSurvey}
    onComplete={(answers) => surveyStore.handleComplete(answers)}
    onDismiss={() => surveyStore.handleDismiss()}
  />
{/if}

<!-- YOLO mode is managed internally — no floating badge -->

<!-- Toast notifications — bottom-right, z-600 -->
<ToastContainer />

<style>
  .app-shell {
    height: 100dvh;
    width: 100vw;
    display: flex;
    overflow: hidden;
    background: var(--bg-primary);
    position: relative;
    /* Subtle radial glow — pulls the pure black off-black */
    background-image: radial-gradient(
      ellipse at 20% 0%,
      rgba(255, 255, 255, 0.015) 0%,
      transparent 60%
    );
  }

  .main-content {
    flex: 1;
    height: 100%;
    display: flex;
    flex-direction: column;
    min-width: 0;
    overflow: hidden;
    background: var(--bg-secondary);
    /* Inset shadow separates content from sidebar without a hard border */
    box-shadow: inset 1px 0 0 rgba(255, 255, 255, 0.04);
    position: relative;
  }

  /* TaskCard anchor — fixed relative to .main-content, bottom-center */
  .task-card-anchor {
    position: absolute;
    bottom: 96px; /* clears the ChatInput dock (approx 80px) + 16px gap */
    left: 50%;
    transform: translateX(-50%);
    z-index: 50;
    /* Prevent the card from overflowing narrow layouts */
    max-width: calc(100% - 32px);
    pointer-events: auto;
  }

</style>
