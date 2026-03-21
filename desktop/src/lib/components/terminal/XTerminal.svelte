<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { restartBackend } from '$lib/utils/backend';
  import { BASE_URL, API_PREFIX, getToken } from '$lib/api/client';

  // xterm types (dynamic import only — avoids SSR issues)
  import type { Terminal as XTermType } from '@xterm/xterm';
  import type { FitAddon } from '@xterm/addon-fit';
  import type { SearchAddon } from '@xterm/addon-search';

  // xterm CSS — must be imported for proper rendering
  import '@xterm/xterm/css/xterm.css';

  // ── Props ─────────────────────────────────────────────────────────────────

  interface Props {
    fontSize?: number;
    onCommandExecute?: (cmd: string) => void;
    onToggleSearch?: () => void;
  }

  let { fontSize = $bindable(13), onCommandExecute, onToggleSearch }: Props = $props();

  // ── Internal state ────────────────────────────────────────────────────────

  let terminalEl = $state<HTMLDivElement | null>(null);
  let term = $state<XTermType | null>(null);
  let fitAddon = $state<FitAddon | null>(null);
  let searchAddon = $state<SearchAddon | null>(null);

  let inputBuffer = $state('');
  let cursorPos = $state(0);
  let isExecuting = $state(false);

  let resizeObserver: ResizeObserver | null = null;
  let resizeTimer: ReturnType<typeof setTimeout> | null = null;

  // ── Command history ───────────────────────────────────────────────────────

  const MAX_HISTORY = 100;
  let history: string[] = [];
  let historyIndex = -1;
  let savedInput = '';

  function addToHistory(cmd: string) {
    if (!cmd.trim()) return;
    if (history.length > 0 && history[0] === cmd) return;
    history.unshift(cmd);
    if (history.length > MAX_HISTORY) history.pop();
    historyIndex = -1;
  }

  // ── Line editing helpers ──────────────────────────────────────────────────

  function clearLine(t: XTermType) {
    if (inputBuffer.length > 0) {
      if (cursorPos > 0) t.write(`\x1b[${cursorPos}D`);
      t.write('\x1b[K');
    }
  }

  function redrawInput(t: XTermType, newBuffer: string, newCursorPos?: number) {
    clearLine(t);
    inputBuffer = newBuffer;
    cursorPos = newCursorPos ?? newBuffer.length;
    t.write(newBuffer);
    const diff = newBuffer.length - cursorPos;
    if (diff > 0) t.write(`\x1b[${diff}D`);
  }

  // ── Terminal theme ────────────────────────────────────────────────────────

  const TERM_THEME = {
    background:          '#0a0a0c',
    foreground:          '#e0e0e0',
    cursor:              '#ffffff',
    cursorAccent:        '#0a0a0c',
    selectionBackground: 'rgba(255,255,255,0.15)',
    black:               '#1a1a1f',
    red:                 '#ef4444',
    green:               '#22c55e',
    yellow:              '#f59e0b',
    blue:                '#3b82f6',
    magenta:             '#a855f7',
    cyan:                '#06b6d4',
    white:               '#e0e0e0',
    brightBlack:         '#555566',
    brightRed:           '#f87171',
    brightGreen:         '#4ade80',
    brightYellow:        '#fbbf24',
    brightBlue:          '#60a5fa',
    brightMagenta:       '#c084fc',
    brightCyan:          '#22d3ee',
    brightWhite:         '#ffffff',
  };

  // ── Prompt ────────────────────────────────────────────────────────────────

  const PROMPT = '\r\n\x1b[38;5;39mosa\x1b[0m \x1b[38;5;240m>\x1b[0m ';

  function writePrompt(t: XTermType) {
    t.write(PROMPT);
  }

  // ── Shell execution ───────────────────────────────────────────────────────

  async function executeCommand(command: string): Promise<void> {
    if (!term || !command.trim()) {
      writePrompt(term!);
      return;
    }

    isExecuting = true;
    term.write('\r\n');

    try {
      const token = getToken();
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      if (token) headers['Authorization'] = `Bearer ${token}`;

      const res = await fetch(`${BASE_URL}${API_PREFIX}/tools/shell_execute/execute`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ command, working_directory: null }),
      });

      if (!res.ok) {
        const errText = await res.text().catch(() => `HTTP ${res.status}`);
        term.write(`\x1b[31mError ${res.status}: ${errText}\x1b[0m`);
      } else {
        const data = (await res.json()) as {
          stdout?: string;
          stderr?: string;
          exit_code?: number;
          output?: string;
          result?: string;
        };

        const stdout = data.stdout ?? data.output ?? data.result ?? '';
        const stderr = data.stderr ?? '';

        if (stdout) term.write(stdout.replace(/\n/g, '\r\n'));
        if (stderr) term.write(`\x1b[31m${stderr.replace(/\n/g, '\r\n')}\x1b[0m`);

        const exitCode = data.exit_code;
        if (typeof exitCode === 'number' && exitCode !== 0) {
          term.write(`\r\n\x1b[33m[exit ${exitCode}]\x1b[0m`);
        }
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      term.write(`\x1b[31m${msg}\x1b[0m`);
    } finally {
      isExecuting = false;
      writePrompt(term!);
      onCommandExecute?.(command);
    }
  }

  // ── Slash command autocomplete ────────────────────────────────────────────

  const SLASH_COMMANDS = ['help', 'clear', 'model', 'new', 'history', 'restart'];

  function getSlashCompletion(buf: string): string | null {
    if (!buf.startsWith('/') || buf.length < 2) return null;
    const typed = buf.slice(1).toLowerCase();
    const match = SLASH_COMMANDS.find(c => c.startsWith(typed) && c !== typed);
    return match ?? null;
  }

  let ghostText = $state('');

  function updateGhost() {
    if (!inputBuffer.startsWith('/') || cursorPos !== inputBuffer.length) {
      ghostText = '';
      return;
    }
    const match = getSlashCompletion(inputBuffer);
    ghostText = match ? match.slice(inputBuffer.length - 1) : '';
  }

  function renderGhost(t: XTermType) {
    if (!ghostText) return;
    t.write(`\x1b[38;5;240m${ghostText}\x1b[0m`);
    t.write(`\x1b[${ghostText.length}D`);
  }

  function clearGhost(t: XTermType) {
    if (!ghostText) return;
    t.write('\x1b[K');
  }

  // ── Slash commands ────────────────────────────────────────────────────────

  function handleSlashCommand(cmd: string, t: XTermType) {
    const parts = cmd.slice(1).split(/\s+/);
    const name = parts[0]?.toLowerCase() ?? '';

    t.write('\r\n');

    switch (name) {
      case 'help':
        t.writeln('\x1b[1m\x1b[38;5;39mAvailable commands:\x1b[0m');
        t.writeln('  \x1b[38;5;39m/help\x1b[0m          Show this help');
        t.writeln('  \x1b[38;5;39m/clear\x1b[0m         Clear the terminal');
        t.writeln('  \x1b[38;5;39m/model\x1b[0m         Show active model');
        t.writeln('  \x1b[38;5;39m/new\x1b[0m           Start new session');
        t.writeln('  \x1b[38;5;39m/history\x1b[0m       Show command history');
        t.writeln('  \x1b[38;5;39m/restart\x1b[0m       Restart the backend');
        t.writeln('');
        t.writeln('\x1b[1mKeyboard shortcuts:\x1b[0m');
        t.writeln('  \x1b[38;5;240mCtrl+L\x1b[0m   Clear screen');
        t.writeln('  \x1b[38;5;240mCtrl+C\x1b[0m   Cancel / clear line');
        t.writeln('  \x1b[38;5;240mCtrl+F\x1b[0m   Toggle search');
        t.writeln('  \x1b[38;5;240mCtrl+A\x1b[0m   Jump to start');
        t.writeln('  \x1b[38;5;240mCtrl+E\x1b[0m   Jump to end');
        t.writeln('  \x1b[38;5;240mCtrl+K\x1b[0m   Delete to end of line');
        t.writeln('  \x1b[38;5;240mCtrl+U\x1b[0m   Delete to start of line');
        t.writeln('  \x1b[38;5;240mCtrl+W\x1b[0m   Delete word back');
        t.writeln('  \x1b[38;5;240m↑/↓\x1b[0m      History navigation');
        break;
      case 'clear':
        t.clear();
        inputBuffer = '';
        cursorPos = 0;
        break;
      case 'model':
        t.writeln('\x1b[38;5;240mQuerying active model...\x1b[0m');
        void (async () => {
          try {
            const token = getToken();
            const headers: Record<string, string> = { Accept: 'application/json' };
            if (token) headers['Authorization'] = `Bearer ${token}`;
            const res = await fetch(`${BASE_URL}${API_PREFIX}/models`, { headers });
            if (res.ok) {
              const models = await res.json() as Array<{ name: string; active?: boolean }>;
              const active = models.find(m => m.active);
              if (active) {
                t.writeln(`\x1b[38;5;39mActive model:\x1b[0m ${active.name}`);
              } else {
                t.writeln('\x1b[38;5;240mNo active model set\x1b[0m');
              }
            } else {
              t.writeln('\x1b[31mBackend offline\x1b[0m');
            }
          } catch {
            t.writeln('\x1b[31mBackend offline\x1b[0m');
          }
          writePrompt(t);
        })();
        return;
      case 'history':
        if (history.length === 0) {
          t.writeln('\x1b[38;5;240mNo command history\x1b[0m');
        } else {
          t.writeln('\x1b[1mCommand history:\x1b[0m');
          const show = history.slice(0, 20);
          show.forEach((h, i) => {
            t.writeln(`  \x1b[38;5;240m${i + 1}.\x1b[0m ${h}`);
          });
          if (history.length > 20) {
            t.writeln(`  \x1b[38;5;240m... and ${history.length - 20} more\x1b[0m`);
          }
        }
        break;
      case 'new':
        t.writeln('\x1b[38;5;39mStarting new session...\x1b[0m');
        history = [];
        historyIndex = -1;
        t.clear();
        t.writeln('\x1b[1m\x1b[38;5;39mOSA\x1b[0m \x1b[38;5;240mTerminal\x1b[0m');
        t.writeln('\x1b[38;5;240mNew session started. Type /help for commands.\x1b[0m');
        break;
      case 'restart':
        t.writeln('\x1b[38;5;39mSending restart signal...\x1b[0m');
        restartBackend()
          .then(() => t.writeln('\x1b[38;5;39mRestart signal sent\x1b[0m'))
          .catch(() => t.writeln('\x1b[31mBackend offline — cannot restart\x1b[0m'))
          .finally(() => writePrompt(t));
        return;
      default:
        t.writeln(`\x1b[31mUnknown command: /${name}\x1b[0m`);
        t.writeln('\x1b[38;5;240mType /help for available commands.\x1b[0m');
        break;
    }

    writePrompt(t);
  }

  // ── xterm initialization ──────────────────────────────────────────────────

  async function initTerminal(container: HTMLDivElement) {
    const { Terminal }      = await import('@xterm/xterm');
    const { FitAddon }      = await import('@xterm/addon-fit');
    const { WebLinksAddon } = await import('@xterm/addon-web-links');
    const { SearchAddon }   = await import('@xterm/addon-search');

    const t = new Terminal({
      fontFamily: "'SF Mono', 'Fira Code', 'Fira Mono', 'Cascadia Code', ui-monospace, monospace",
      fontSize,
      lineHeight: 1.4,
      letterSpacing: 0,
      cursorBlink: true,
      cursorStyle: 'block',
      theme: TERM_THEME,
      allowProposedApi: true,
      scrollback: 5000,
      convertEol: false,
      windowsMode: false,
      macOptionIsMeta: true,
    });

    const fit  = new FitAddon();
    const wla  = new WebLinksAddon();
    const srch = new SearchAddon();

    t.loadAddon(fit);
    t.loadAddon(wla);
    t.loadAddon(srch);

    t.open(container);
    fit.fit();

    t.writeln('\x1b[1m\x1b[38;5;39mOSA\x1b[0m \x1b[38;5;240mTerminal\x1b[0m');
    t.writeln('\x1b[38;5;240mType a command or /help for available commands.\x1b[0m');
    t.writeln('\x1b[38;5;240mCtrl+L clear | Ctrl+F search | ↑↓ history | Ctrl+A/E home/end\x1b[0m');
    writePrompt(t);

    // Full readline-emulation key handler
    t.onKey(({ key, domEvent }) => {
      const ev = domEvent;

      // Tab — complete slash command
      if (ev.key === 'Tab') {
        ev.preventDefault();
        const match = getSlashCompletion(inputBuffer);
        if (match && cursorPos === inputBuffer.length) {
          clearGhost(t);
          const completion = match.slice(inputBuffer.length - 1);
          inputBuffer += completion;
          cursorPos = inputBuffer.length;
          t.write(completion);
          ghostText = '';
        }
        return;
      }

      // Ctrl+C — interrupt
      if (ev.ctrlKey && ev.key === 'c') {
        clearGhost(t);
        if (isExecuting) {
          isExecuting = false;
          t.write('^C');
        } else {
          t.write('^C');
          inputBuffer = '';
          cursorPos = 0;
        }
        ghostText = '';
        writePrompt(t);
        return;
      }

      // Ctrl+L — clear screen
      if (ev.ctrlKey && ev.key === 'l') {
        t.clear();
        inputBuffer = '';
        cursorPos = 0;
        writePrompt(t);
        return;
      }

      // Ctrl+F — request search toggle (delegated to parent via event)
      if (ev.ctrlKey && ev.key === 'f') {
        onToggleSearch?.();
        return;
      }

      // Ctrl+A — jump to start
      if (ev.ctrlKey && ev.key === 'a') {
        if (cursorPos > 0) {
          t.write(`\x1b[${cursorPos}D`);
          cursorPos = 0;
        }
        return;
      }

      // Ctrl+E — jump to end
      if (ev.ctrlKey && ev.key === 'e') {
        const diff = inputBuffer.length - cursorPos;
        if (diff > 0) {
          t.write(`\x1b[${diff}C`);
          cursorPos = inputBuffer.length;
        }
        return;
      }

      // Ctrl+K — delete to end of line
      if (ev.ctrlKey && ev.key === 'k') {
        if (cursorPos < inputBuffer.length) {
          t.write('\x1b[K');
          inputBuffer = inputBuffer.slice(0, cursorPos);
        }
        return;
      }

      // Ctrl+U — delete to start of line
      if (ev.ctrlKey && ev.key === 'u') {
        if (cursorPos > 0) {
          const rest = inputBuffer.slice(cursorPos);
          t.write(`\x1b[${cursorPos}D\x1b[K`);
          inputBuffer = rest;
          cursorPos = 0;
          t.write(rest);
          if (rest.length > 0) t.write(`\x1b[${rest.length}D`);
        }
        return;
      }

      // Ctrl+W — delete word back
      if (ev.ctrlKey && ev.key === 'w') {
        if (cursorPos > 0) {
          const before = inputBuffer.slice(0, cursorPos);
          const after = inputBuffer.slice(cursorPos);
          const wordStart = before.trimEnd().lastIndexOf(' ') + 1;
          const deleted = cursorPos - wordStart;
          if (deleted > 0) {
            const newBuf = before.slice(0, wordStart) + after;
            t.write(`\x1b[${deleted}D\x1b[K`);
            cursorPos = wordStart;
            inputBuffer = newBuf;
            t.write(after);
            if (after.length > 0) t.write(`\x1b[${after.length}D`);
          }
        }
        return;
      }

      if (isExecuting) return;

      // Enter — execute
      if (ev.key === 'Enter') {
        clearGhost(t);
        ghostText = '';
        const cmd = inputBuffer;
        addToHistory(cmd);
        inputBuffer = '';
        cursorPos = 0;
        historyIndex = -1;

        if (cmd.startsWith('/')) {
          handleSlashCommand(cmd, t);
          return;
        }

        void executeCommand(cmd);
        return;
      }

      // Up — history back
      if (ev.key === 'ArrowUp') {
        clearGhost(t);
        ghostText = '';
        if (history.length === 0) return;
        if (historyIndex === -1) savedInput = inputBuffer;
        if (historyIndex < history.length - 1) {
          historyIndex++;
          redrawInput(t, history[historyIndex]);
        }
        return;
      }

      // Down — history forward
      if (ev.key === 'ArrowDown') {
        clearGhost(t);
        ghostText = '';
        if (historyIndex <= 0) {
          if (historyIndex === 0) {
            historyIndex = -1;
            redrawInput(t, savedInput);
          }
          return;
        }
        historyIndex--;
        redrawInput(t, history[historyIndex]);
        return;
      }

      // Left
      if (ev.key === 'ArrowLeft') {
        if (cursorPos > 0) {
          cursorPos--;
          t.write('\x1b[D');
        }
        return;
      }

      // Right
      if (ev.key === 'ArrowRight') {
        if (cursorPos < inputBuffer.length) {
          cursorPos++;
          t.write('\x1b[C');
        }
        return;
      }

      // Home
      if (ev.key === 'Home') {
        if (cursorPos > 0) {
          t.write(`\x1b[${cursorPos}D`);
          cursorPos = 0;
        }
        return;
      }

      // End
      if (ev.key === 'End') {
        const diff = inputBuffer.length - cursorPos;
        if (diff > 0) {
          t.write(`\x1b[${diff}C`);
          cursorPos = inputBuffer.length;
        }
        return;
      }

      // Backspace
      if (ev.key === 'Backspace') {
        clearGhost(t);
        if (cursorPos > 0) {
          const before = inputBuffer.slice(0, cursorPos - 1);
          const after = inputBuffer.slice(cursorPos);
          inputBuffer = before + after;
          cursorPos--;
          t.write('\b');
          t.write(after + ' ');
          t.write(`\x1b[${after.length + 1}D`);
          updateGhost();
          renderGhost(t);
        }
        return;
      }

      // Delete
      if (ev.key === 'Delete') {
        if (cursorPos < inputBuffer.length) {
          const before = inputBuffer.slice(0, cursorPos);
          const after = inputBuffer.slice(cursorPos + 1);
          inputBuffer = before + after;
          t.write(after + ' ');
          t.write(`\x1b[${after.length + 1}D`);
        }
        return;
      }

      // Ignore non-printable / modifier-only
      if (ev.ctrlKey || ev.altKey || ev.metaKey) return;
      if (key.length !== 1) return;

      // Printable character — insert at cursor
      clearGhost(t);
      const before = inputBuffer.slice(0, cursorPos);
      const after = inputBuffer.slice(cursorPos);
      inputBuffer = before + key + after;
      cursorPos++;
      t.write(key + after);
      if (after.length > 0) t.write(`\x1b[${after.length}D`);

      updateGhost();
      renderGhost(t);
    });

    term = t;
    fitAddon = fit;
    searchAddon = srch;

    resizeObserver = new ResizeObserver(() => {
      if (resizeTimer !== null) clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => fit.fit(), 80);
    });
    resizeObserver.observe(container);
  }

  // ── Font size reactivity ──────────────────────────────────────────────────

  $effect(() => {
    if (term && fontSize) {
      term.options.fontSize = fontSize;
      fitAddon?.fit();
    }
  });

  // ── Public API (via bind:this) ────────────────────────────────────────────

  export function clear() {
    term?.clear();
    inputBuffer = '';
    if (term) writePrompt(term);
  }

  export function focus() {
    term?.focus();
  }

  export function search(query: string) {
    if (query) {
      searchAddon?.findNext(query, { incremental: true, caseSensitive: false });
    }
  }

  export function searchNext(query: string) {
    if (query) searchAddon?.findNext(query, { caseSensitive: false });
  }

  export function searchPrev(query: string) {
    if (query) searchAddon?.findPrevious(query, { caseSensitive: false });
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  onMount(async () => {
    await Promise.resolve();
    if (terminalEl) await initTerminal(terminalEl);
  });

  onDestroy(() => {
    resizeObserver?.disconnect();
    if (resizeTimer !== null) clearTimeout(resizeTimer);
    term?.dispose();
  });
</script>

<div class="xt-body">
  <div
    bind:this={terminalEl}
    class="xt-container"
    aria-label="Terminal"
    role="application"
  ></div>

  {#if isExecuting}
    <div class="xt-exec-indicator" aria-live="polite" aria-label="Executing command">
      <span class="xt-exec-dot"></span>
      <span class="xt-exec-dot"></span>
      <span class="xt-exec-dot"></span>
    </div>
  {/if}
</div>

<style>
  .xt-body {
    flex: 1;
    position: relative;
    overflow: hidden;
  }

  .xt-container {
    width: 100%;
    height: 100%;
    padding: 8px 4px 4px 4px;
  }

  /* Override xterm.js internals for seamless integration */
  :global(.xterm) {
    height: 100%;
    padding: 0 !important;
  }

  :global(.xterm-viewport) {
    border-radius: 0 !important;
    overflow-y: auto !important;
  }

  :global(.xterm-viewport::-webkit-scrollbar) {
    width: 5px;
  }

  :global(.xterm-viewport::-webkit-scrollbar-thumb) {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 9999px;
  }

  :global(.xterm-viewport::-webkit-scrollbar-thumb:hover) {
    background: rgba(255, 255, 255, 0.18);
  }

  :global(.xterm-screen) {
    padding-left: 8px !important;
  }

  /* Executing indicator */
  .xt-exec-indicator {
    position: absolute;
    bottom: 12px;
    right: 16px;
    display: flex;
    align-items: center;
    gap: 4px;
    pointer-events: none;
  }

  .xt-exec-dot {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: rgba(59, 130, 246, 0.7);
    animation: xt-exec-pulse 1s ease-in-out infinite;
  }

  .xt-exec-dot:nth-child(2) { animation-delay: 0.2s; }
  .xt-exec-dot:nth-child(3) { animation-delay: 0.4s; }

  @keyframes xt-exec-pulse {
    0%, 80%, 100% { opacity: 0.2; transform: scale(0.85); }
    40%           { opacity: 1;   transform: scale(1); }
  }
</style>
