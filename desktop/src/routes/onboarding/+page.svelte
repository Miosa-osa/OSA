<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { fly } from 'svelte/transition';
  import { cubicOut, cubicIn } from 'svelte/easing';
  import type { Provider, OnboardingStep, DetectionResult, WorkspaceConfig } from '$lib/onboarding/types';
  import { detectLocalProviders } from '$lib/onboarding/detection';
  import { completeOnboarding, getDefaultWorkingDirectory } from '$lib/onboarding/store';
  import StepWorkspace from './steps/StepWorkspace.svelte';
  import StepAgent from './steps/StepAgent.svelte';
  import StepFirstTask from './steps/StepFirstTask.svelte';
  import StepLaunch from './steps/StepLaunch.svelte';

  // ── State ────────────────────────────────────────────────────────────
  let step = $state<OnboardingStep>(1);
  let direction = $state<1 | -1>(1);

  // Step 1: workspace
  let workspace = $state<WorkspaceConfig>({ name: '', workingDirectory: '' });

  // Step 2: agent
  let provider = $state<Provider | null>(null);
  let detectedProviders = $state<DetectionResult>({ ollama: false, lmstudio: false });
  let detecting = $state(true);
  let apiKey = $state('');
  let agentName = $state('OSA Agent');

  // Step 3: first task
  let firstTask = $state('');

  let containerRef = $state<HTMLElement | null>(null);

  // ── Derived ──────────────────────────────────────────────────────────
  let visualStep = $derived(
    step === 'complete' ? 4
    : step === 1 ? 1
    : step === 2 ? 2
    : step === 3 ? 3
    : 4
  );

  // ── Lifecycle ────────────────────────────────────────────────────────
  onMount(async () => {
    const [detected, defaultDir] = await Promise.all([
      detectLocalProviders(),
      getDefaultWorkingDirectory(),
    ]);

    detectedProviders = detected;
    workspace = { ...workspace, workingDirectory: defaultDir };
    detecting = false;

    // Auto-select first detected local provider
    if (detected.ollama) provider = 'ollama';
    else if (detected.lmstudio) provider = 'lmstudio';
  });

  // Focus first interactive element after transitions settle
  $effect(() => {
    step; // reactive — intentional read to track step changes
    if (!containerRef) return;
    const prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const delay = prefersReduced ? 0 : 220;
    const t = setTimeout(() => {
      const first = containerRef?.querySelector<HTMLElement>(
        'button:not([disabled]), input, textarea, [href]'
      );
      first?.focus();
    }, delay);
    return () => clearTimeout(t);
  });

  // ── Navigation ───────────────────────────────────────────────────────
  function back() {
    direction = -1;
    if (step === 2) step = 1;
    else if (step === 3) step = 2;
    else if (step === 4) step = 3;
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape' && step !== 1 && step !== 'complete') {
      back();
    }
  }

  // ── Step handlers ────────────────────────────────────────────────────
  function handleWorkspaceDone(ws: WorkspaceConfig) {
    workspace = ws;
    direction = 1;
    step = 2;
  }

  function handleAgentDone(opts: { provider: Provider; apiKey: string; agentName: string }) {
    provider = opts.provider;
    apiKey = opts.apiKey;
    agentName = opts.agentName;
    direction = 1;
    step = 3;
  }

  function handleFirstTaskDone(task: string) {
    firstTask = task;
    direction = 1;
    step = 4;
  }

  async function handleLaunch(): Promise<void> {
    if (!provider) return;
    await completeOnboarding({
      workspace,
      provider,
      apiKey,
      agentName,
      firstTask: firstTask || undefined,
    });
    // StepLaunch manages the post-launch success animation + redirect
    setTimeout(() => goto('/app'), 2000);
  }

  // Fly params — zero duration if reduced motion
  function flyIn() {
    const reduced = typeof window !== 'undefined'
      ? window.matchMedia('(prefers-reduced-motion: reduce)').matches
      : false;
    return reduced ? { duration: 0 } : { x: direction * 28, duration: 200, easing: cubicOut };
  }

  function flyOut() {
    const reduced = typeof window !== 'undefined'
      ? window.matchMedia('(prefers-reduced-motion: reduce)').matches
      : false;
    return reduced ? { duration: 0 } : { x: direction * -28, duration: 160, easing: cubicIn };
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="ob-root dark" bind:this={containerRef}>
  <!-- Ambient background glow -->
  <div class="ob-ambient" aria-hidden="true"></div>

  <div class="ob-frame ob-glass">
    <!-- Header -->
    <header class="ob-header">
      <div class="ob-logo" aria-label="OSA">
        <video
          class="ob-logo-video"
          src="/OSLoopingActiveMode.mp4"
          autoplay
          loop
          muted
          playsinline
          aria-hidden="true"
        ></video>
        <span class="ob-logo-name">Canopy</span>
      </div>
    </header>

    <!-- Step content with fly transition -->
    <main class="ob-content" id="ob-main" tabindex="-1">
      {#key step}
        <div
          in:fly={flyIn()}
          out:fly={flyOut()}
          class="ob-step"
        >
          {#if step === 1}
            <StepWorkspace
              {workspace}
              onNext={handleWorkspaceDone}
            />
          {:else if step === 2}
            <StepAgent
              {provider}
              {detectedProviders}
              {detecting}
              bind:apiKey
              bind:agentName
              onSelect={(p) => { provider = p; }}
              onNext={handleAgentDone}
              onBack={back}
            />
          {:else if step === 3}
            <StepFirstTask
              bind:firstTask
              onNext={handleFirstTaskDone}
              onBack={back}
            />
          {:else if step === 4 && provider}
            <StepLaunch
              {workspace}
              {provider}
              {agentName}
              {firstTask}
              onLaunch={handleLaunch}
              onBack={back}
            />
          {/if}
        </div>
      {/key}
    </main>

    <!-- Progress dots (hidden on complete) -->
    {#if step !== 'complete'}
      <footer class="ob-footer">
        <div
          class="ob-dots"
          role="progressbar"
          aria-label="Setup progress"
          aria-valuenow={visualStep}
          aria-valuemin={1}
          aria-valuemax={4}
        >
          {#each [1, 2, 3, 4] as dot}
            <div
              class="ob-dot"
              class:ob-dot--active={visualStep === dot}
              class:ob-dot--done={visualStep > dot}
            ></div>
          {/each}
        </div>
      </footer>
    {/if}
  </div>
</div>

<style>
  .ob-root {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #0a0a0a;
    overflow: hidden;
  }

  /* Subtle ambient glow */
  .ob-ambient {
    position: absolute;
    inset: 0;
    background:
      radial-gradient(ellipse 60% 40% at 30% 60%, rgba(255, 255, 255, 0.015) 0%, transparent 70%),
      radial-gradient(ellipse 50% 50% at 70% 30%, rgba(255, 255, 255, 0.01) 0%, transparent 70%);
    pointer-events: none;
  }

  /* Main glass frame */
  .ob-frame {
    position: relative;
    width: 100%;
    max-width: 520px;
    min-height: 500px;
    display: flex;
    flex-direction: column;
    z-index: 1;
  }

  .ob-glass {
    background: rgba(255, 255, 255, 0.03);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 20px;
    box-shadow: 0 8px 40px rgba(0, 0, 0, 0.5);
  }

  .ob-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 28px 0;
  }

  .ob-logo {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .ob-logo-video {
    width: 28px;
    height: 28px;
    border-radius: 6px;
    object-fit: cover;
    pointer-events: none;
  }

  .ob-logo-name {
    font-size: 14px;
    font-weight: 700;
    color: #ffffff;
    letter-spacing: 0.04em;
  }

  /* ── Shared button styles (used by step components) ── */
  :global(.ob-btn) {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 9px 18px;
    border-radius: 10px;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    border: none;
    transition: background 0.15s ease, opacity 0.15s ease, transform 0.1s ease;
    user-select: none;
  }

  :global(.ob-btn:focus-visible) {
    outline: 2px solid rgba(255, 255, 255, 0.4);
    outline-offset: 2px;
  }

  :global(.ob-btn:disabled) {
    opacity: 0.35;
    cursor: not-allowed;
  }

  :global(.ob-btn--primary) {
    background: #ffffff;
    color: #0a0a0a;
  }

  :global(.ob-btn--primary:hover:not(:disabled)) {
    opacity: 0.9;
  }

  :global(.ob-btn--primary:active:not(:disabled)) {
    transform: scale(0.98);
  }

  :global(.ob-btn--ghost) {
    background: transparent;
    color: #666666;
    border: 1px solid transparent;
  }

  :global(.ob-btn--ghost:hover:not(:disabled)) {
    color: #a0a0a0;
    background: rgba(255, 255, 255, 0.04);
  }

  .ob-content {
    flex: 1;
    position: relative;
    overflow: hidden;
    padding: 32px 28px 24px;
  }

  .ob-content:focus {
    outline: none;
  }

  .ob-step {
    position: absolute;
    inset: 32px 28px 24px;
    display: flex;
    flex-direction: column;
  }

  .ob-footer {
    padding: 0 28px 24px;
    display: flex;
    justify-content: center;
  }

  .ob-dots {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .ob-dot {
    width: 6px;
    height: 6px;
    border-radius: 9999px;
    background: rgba(255, 255, 255, 0.15);
    transition: all 0.25s ease;
  }

  .ob-dot--active {
    width: 20px;
    background: rgba(255, 255, 255, 0.7);
  }

  .ob-dot--done {
    background: rgba(255, 255, 255, 0.35);
  }
</style>
