<script lang="ts">
  import { onMount } from 'svelte';

  interface Props {
    onDone: () => void;
  }

  let { onDone }: Props = $props();

  let visible = $state(false);

  onMount(() => {
    // Tiny delay so the fly-in transition settles before the checkmark draws
    const show = setTimeout(() => { visible = true; }, 80);
    const done = setTimeout(() => { onDone(); }, 1880);
    return () => { clearTimeout(show); clearTimeout(done); };
  });
</script>

<div class="sc-root" aria-live="polite" aria-label="Setup complete">
  <div class="sc-check-wrap" class:sc-check-wrap--visible={visible}>
    <svg
      class="sc-check"
      viewBox="0 0 52 52"
      fill="none"
      aria-hidden="true"
    >
      <circle class="sc-circle" cx="26" cy="26" r="24" stroke="#22c55e" stroke-width="2" />
      <path
        class="sc-path"
        d="M14 26 L22 34 L38 18"
        stroke="#22c55e"
        stroke-width="2.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  </div>

  <p class="sc-title" class:sc-title--visible={visible}>You're all set.</p>
  <p class="sc-sub" class:sc-sub--visible={visible}>OSA is ready.</p>
</div>

<style>
  .sc-root {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    height: 100%;
    gap: 16px;
    text-align: center;
  }

  .sc-check-wrap {
    width: 64px;
    height: 64px;
    opacity: 0;
    transform: scale(0.8);
    transition: opacity 0.3s ease, transform 0.3s ease;
  }

  .sc-check-wrap--visible {
    opacity: 1;
    transform: scale(1);
  }

  .sc-check {
    width: 64px;
    height: 64px;
  }

  /* SVG stroke draw animation */
  .sc-circle {
    stroke-dasharray: 157;
    stroke-dashoffset: 157;
    animation: sc-draw-circle 0.5s ease-out 0.1s forwards;
  }

  .sc-path {
    stroke-dasharray: 36;
    stroke-dashoffset: 36;
    animation: sc-draw-check 0.35s ease-out 0.5s forwards;
  }

  @keyframes sc-draw-circle {
    to { stroke-dashoffset: 0; }
  }

  @keyframes sc-draw-check {
    to { stroke-dashoffset: 0; }
  }

  .sc-title {
    font-size: 20px;
    font-weight: 700;
    color: #ffffff;
    letter-spacing: -0.02em;
    margin: 0;
    opacity: 0;
    transform: translateY(6px);
    transition: opacity 0.3s ease 0.7s, transform 0.3s ease 0.7s;
  }

  .sc-title--visible {
    opacity: 1;
    transform: translateY(0);
  }

  .sc-sub {
    font-size: 13px;
    color: #666666;
    margin: 0;
    opacity: 0;
    transform: translateY(6px);
    transition: opacity 0.3s ease 0.85s, transform 0.3s ease 0.85s;
  }

  .sc-sub--visible {
    opacity: 1;
    transform: translateY(0);
  }

  @media (prefers-reduced-motion: reduce) {
    .sc-circle,
    .sc-path,
    .sc-check-wrap,
    .sc-title,
    .sc-sub {
      animation: none;
      transition: none;
      opacity: 1;
      transform: none;
      stroke-dashoffset: 0;
    }
  }
</style>
