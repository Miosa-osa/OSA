<script lang="ts">
  import { voiceStore } from '$lib/stores/voice.svelte';
</script>

<section class="sv-section">
  <h2 class="sv-section-title">Voice Input</h2>
  <p class="sv-section-desc">Configure speech-to-text for voice commands.</p>

  <div class="sv-settings-group">
    <!-- Voice provider -->
    <div class="sv-settings-item">
      <div class="sv-item-meta">
        <span class="sv-item-label">Transcription provider</span>
        <span class="sv-item-hint">How voice audio is converted to text.</span>
      </div>
      <select
        class="sv-field-select"
        value={voiceStore.provider}
        onchange={(e) => voiceStore.setProvider((e.target as HTMLSelectElement).value as 'local' | 'groq' | 'openai' | 'browser')}
        aria-label="Voice provider"
      >
        <option value="local">Local (no key needed, live transcript)</option>
        <option value="groq">Groq Whisper (fast, cloud)</option>
        <option value="openai">OpenAI Whisper (cloud)</option>
        <option value="browser" disabled={!voiceStore.hasBrowserSpeech}>
          Browser Speech API {voiceStore.hasBrowserSpeech ? '' : '(not available)'}
        </option>
      </select>
    </div>

    <div class="sv-item-divider"></div>

    <!-- Groq API key -->
    <div class="sv-settings-item">
      <div class="sv-item-meta">
        <span class="sv-item-label">Groq API key</span>
        <span class="sv-item-hint">For Groq Whisper transcription. Get one at console.groq.com</span>
      </div>
      <div class="sv-key-row">
        <input
          type="password"
          class="sv-field-input"
          value={voiceStore.groqKey}
          onchange={(e) => voiceStore.setGroqKey((e.target as HTMLInputElement).value)}
          placeholder="gsk_..."
          aria-label="Groq API key"
          spellcheck={false}
          autocomplete="off"
        />
        {#if voiceStore.groqKey}
          <span class="sv-key-status sv-key-status--ok">Set</span>
        {:else}
          <span class="sv-key-status sv-key-status--missing">Missing</span>
        {/if}
      </div>
    </div>

    <div class="sv-item-divider"></div>

    <!-- OpenAI API key -->
    <div class="sv-settings-item">
      <div class="sv-item-meta">
        <span class="sv-item-label">OpenAI API key</span>
        <span class="sv-item-hint">For OpenAI Whisper transcription.</span>
      </div>
      <div class="sv-key-row">
        <input
          type="password"
          class="sv-field-input"
          value={voiceStore.openaiKey}
          onchange={(e) => voiceStore.setOpenaiKey((e.target as HTMLInputElement).value)}
          placeholder="sk-..."
          aria-label="OpenAI API key"
          spellcheck={false}
          autocomplete="off"
        />
        {#if voiceStore.openaiKey}
          <span class="sv-key-status sv-key-status--ok">Set</span>
        {:else}
          <span class="sv-key-status sv-key-status--missing">Missing</span>
        {/if}
      </div>
    </div>

    <div class="sv-item-divider"></div>

    <!-- Test voice -->
    <div class="sv-settings-item">
      <div class="sv-item-meta">
        <span class="sv-item-label">Test voice input</span>
        <span class="sv-item-hint">Record a short clip to verify your setup works.</span>
      </div>
      <button
        type="button"
        class="sv-btn-ghost sv-btn-sm"
        onclick={() => {
          voiceStore.toggle((text) => {
            alert(`Transcribed: "${text}"`);
          });
        }}
        aria-label="Test voice"
      >
        {voiceStore.isListening ? 'Stop' : voiceStore.isTranscribing ? 'Transcribing...' : 'Test mic'}
      </button>
    </div>

    {#if voiceStore.error}
      <div class="sv-voice-error">
        {voiceStore.error}
      </div>
    {/if}
  </div>
</section>

<style>
  .sv-section { max-width: 560px; }

  .sv-section-title {
    font-size: 18px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    margin: 0 0 4px;
  }

  .sv-section-desc {
    font-size: 13px;
    color: var(--text-tertiary);
    margin: 0 0 24px;
  }

  .sv-settings-group {
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 12px;
    overflow: hidden;
  }

  .sv-settings-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 13px 16px;
    min-height: 52px;
  }

  .sv-item-divider {
    height: 1px;
    background: rgba(255, 255, 255, 0.06);
  }

  .sv-item-meta {
    display: flex;
    flex-direction: column;
    gap: 2px;
    flex-shrink: 0;
  }

  .sv-item-label {
    font-size: 14px;
    color: rgba(255, 255, 255, 0.88);
    font-weight: 450;
    white-space: nowrap;
  }

  .sv-item-hint {
    font-size: 11.5px;
    color: var(--text-tertiary);
  }

  .sv-field-input {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 8px;
    padding: 7px 12px;
    color: rgba(255, 255, 255, 0.9);
    font-size: 13px;
    outline: none;
    transition: border-color 0.15s ease, background 0.15s ease;
    width: 220px;
    min-width: 0;
  }

  .sv-field-input::placeholder { color: rgba(255, 255, 255, 0.2); }

  .sv-field-input:focus {
    border-color: rgba(255, 255, 255, 0.22);
    background: rgba(255, 255, 255, 0.07);
  }

  .sv-field-select {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 8px;
    padding: 7px 28px 7px 12px;
    color: rgba(255, 255, 255, 0.9);
    font-size: 13px;
    outline: none;
    cursor: pointer;
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='10' viewBox='0 0 24 24' fill='none' stroke='%23666' stroke-width='2.5' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M6 9l6 6 6-6'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 10px center;
    transition: border-color 0.15s ease;
  }

  .sv-field-select:focus { border-color: rgba(255, 255, 255, 0.22); }

  .sv-key-row {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .sv-key-status {
    font-size: 0.7rem;
    font-weight: 600;
    letter-spacing: 0.05em;
    padding: 2px 8px;
    border-radius: 9999px;
    flex-shrink: 0;
  }

  .sv-key-status--ok {
    color: #4ade80;
    background: rgba(74, 222, 128, 0.1);
    border: 1px solid rgba(74, 222, 128, 0.2);
  }

  .sv-key-status--missing {
    color: rgba(255, 255, 255, 0.35);
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
  }

  .sv-voice-error {
    margin-top: 8px;
    padding: 8px 12px;
    font-size: 0.75rem;
    color: rgba(251, 191, 36, 0.8);
    background: rgba(251, 191, 36, 0.06);
    border: 1px solid rgba(251, 191, 36, 0.1);
    border-radius: 8px;
  }

  .sv-btn-ghost {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 9999px;
    color: rgba(255, 255, 255, 0.6);
    font-size: 13px;
    font-weight: 450;
    cursor: pointer;
    transition: background 0.13s ease, color 0.13s ease, border-color 0.13s ease;
  }

  .sv-btn-ghost:hover:not(:disabled) {
    background: rgba(255, 255, 255, 0.07);
    color: rgba(255, 255, 255, 0.85);
    border-color: rgba(255, 255, 255, 0.13);
  }

  .sv-btn-ghost:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.3);
    outline-offset: 2px;
  }

  .sv-btn-sm { padding: 6px 10px; font-size: 12px; }
</style>
