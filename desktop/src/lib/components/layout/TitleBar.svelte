<script lang="ts">
  import { browser } from '$app/environment';
  import { isMacOS } from '$lib/utils/platform';

  interface Props {
    title?: string;
  }

  let { title = 'OSA' }: Props = $props();

  const onMac = $derived(browser && isMacOS());
  const trafficLightOffset = $derived(onMac ? '72px' : '16px');
</script>

<div
  class="titlebar"
  data-tauri-drag-region
>
  <div class="titlebar-left" style:width={trafficLightOffset}></div>

  <div class="titlebar-center" data-tauri-drag-region>
    <span class="titlebar-title">{title}</span>
  </div>

  <div class="titlebar-right"></div>
</div>

<style>
  .titlebar {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 44px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    background: transparent;
    z-index: var(--z-fixed);
    -webkit-app-region: drag;
    app-region: drag;
  }

  .titlebar-left {
    flex-shrink: 0;
    height: 100%;
  }

  .titlebar-center {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .titlebar-title {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-tertiary);
    letter-spacing: 0.02em;
    pointer-events: none;
    user-select: none;
  }

  .titlebar-right {
    width: 72px;
    flex-shrink: 0;
  }
</style>
