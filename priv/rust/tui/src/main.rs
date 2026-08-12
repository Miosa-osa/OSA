use anyhow::Result;
use crossterm::{
    event::{
        DisableBracketedPaste, DisableFocusChange, DisableMouseCapture, EnableBracketedPaste,
        EnableFocusChange, KeyboardEnhancementFlags, PopKeyboardEnhancementFlags,
        PushKeyboardEnhancementFlags,
    },
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, LeaveAlternateScreen},
};
use ratatui::{Terminal, TerminalOptions, Viewport};
use std::io::{self, Write};
use tracing::error;

mod a11y;
mod app;
mod client;
mod clipboard;
#[cfg(test)] mod tool_outcome_tests;
mod components;
mod config;
mod event;
mod logging;
mod notification;
mod render;
mod style;
mod view;
mod dialogs;
mod util;
mod terminal_title;
mod tools;
mod voice;

/// A vt100-backed `ratatui::Backend` giving tests a real terminal emulator.
#[cfg(test)]
mod test_backend;
/// Scoped, restoring overrides for the process-global environment.
#[cfg(test)]
mod test_env;
/// The band arbiter's contract: rects derive from measurements, bands tile the
/// region, and the composer is never shed.
#[cfg(test)]
mod layout_contract;
/// Reserved-vs-drawn layout invariants for the live-region components.
#[cfg(test)]
mod layout_invariants;

fn main() -> Result<()> {
    // Parse CLI args
    let cli = config::cli::Cli::parse_args();

    // Init logging BEFORE terminal (crash recovery)
    logging::init(&cli)?;

    // Install panic hook that restores terminal
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = restore_terminal();
        // In normal operation there is no alt screen — the last inline frame
        // stays on screen and the crash text prints just below it.
        eprintln!("\n\x1b[1;31mOSA Agent crashed!\x1b[0m");
        eprintln!("{}", info);
        if let Some(location) = info.location() {
            eprintln!(
                "  at {}:{}:{}",
                location.file(),
                location.line(),
                location.column()
            );
        }
        eprintln!("\nLogs: ~/.osa/logs/tui.log");
        error!("PANIC: {}", info);
        default_hook(info);
    }));

    // Build and run
    let result = run(cli);

    // Always restore terminal
    restore_terminal()?;

    // ONLY NOW is it safe to write to the terminal. The inline viewport is
    // repainted as part of teardown, so anything printed before
    // `restore_terminal()` is scrolled over / wiped; printing here lands the
    // block in the shell's real scrollback, above the returning prompt.
    match result {
        Ok(app::resume::ExitOutcome::Normal(hint)) => {
            if let Some(block) = hint.as_ref() {
                print!("{}", block);
                let _ = io::stdout().flush();
            }
            Ok(())
        }
        // Loud failure: stderr + exit 2, matching the CLI parser's contract for
        // "you asked for something I could not do".
        Ok(app::resume::ExitOutcome::Failed(msg)) => {
            eprintln!("{}", msg);
            let _ = io::stderr().flush();
            std::process::exit(2);
        }
        Err(e) => Err(e),
    }
}

/// Inline viewport height for the live region (Claude-Code chrome). Sized to the
/// ALWAYS-present chrome only, so an idle live region reserves NO dead rows:
///   ctx-hint (1) + input box (3: top divider + text + bottom divider) +
///   status region (2: status line + permission/shell line) = 6 rows minimum.
/// The streaming preview and thinking/activity rows are added on demand (they are
/// 0 when idle), so the composer sits tight against the last scrollback message —
/// no big gap. Finished replies go to native scrollback, keeping the preview compact.
pub const LIVE_H_BASE: u16 = 6;

/// Clamp the inline viewport height to something sane for the terminal size.
/// Never exceed `term_rows - 1` so tiny terminals don't overflow the viewport.
fn compute_viewport_height(term_rows: u16) -> u16 {
    LIVE_H_BASE.min(term_rows.saturating_sub(1).max(1))
}

fn run(cli: config::cli::Cli) -> Result<app::resume::ExitOutcome> {
    // Load config
    let cfg = config::Config::load(&cli)?;

    // Setup terminal — NO alt screen. Bracketed paste keeps the Ctrl+V / paste
    // flow working, and mouse capture lets the user click into the composer and
    // position the caret. Capturing the mouse hands wheel events to the app
    // instead of the terminal's native scrollback; users reach scrollback with
    // Shift+wheel (terminal bypass) or the Ctrl+O transcript reader.
    enable_raw_mode()?;
    // NOTE: mouse capture is intentionally NOT enabled. Capturing the mouse
    // steals the wheel from the terminal's native scrollback, which forced an
    // in-app transcript overlay on scroll — jarring and un-terminal-like. Like
    // Claude Code, we leave the mouse to the terminal so scroll-up/down just
    // scrolls the conversation, nothing changes. Bracketed paste stays on.
    execute!(io::stdout(), EnableBracketedPaste)?;

    // U-T11: enable DECSET 1004 focus reporting so the terminal emits
    // FocusGained/FocusLost (CSI I / CSI O). The `notification::focus` module
    // folds those into a process-global `is_focused()` flag, replacing the old
    // 10s last-keypress idle heuristic for the turn-complete notifier. A no-op
    // on terminals that don't implement 1004 (they just never send the events,
    // and focus stays reported as `true` — we degrade to always-notify).
    let _ = execute!(io::stdout(), EnableFocusChange);

    // Enable the kitty keyboard protocol's disambiguation so distinct keys like
    // Shift+Enter (insert newline) are reported as Enter+SHIFT instead of collapsing
    // to a bare Enter (submit). Supported by ghostty/wezterm/kitty/foot; a no-op on
    // terminals that don't advertise support, so it's safe to attempt unconditionally
    // behind the capability probe.
    // Capture whether the protocol was actually pushed so the runtime knows if
    // Shift+Enter is a reliable newline chord (kitty terminals) or collapses to a
    // bare Enter (Apple Terminal / VS Code / tmux / SSH). Threaded into App::new so
    // the composer's newline hint matches reality without a re-probe syscall.
    //
    // BATCHED STARTUP PROBE (replaces the old sequential probes). Previously OSA
    // ran a `supports_keyboard_enhancement()` retry loop AND a separate
    // `cursor::position()` priming loop; they raced each other during OSA's busy
    // startup, which flaked the inline-viewport DSR query AND made Shift+Enter
    // unreliable (the kbd probe would return `false` on a terminal that actually
    // supports the kitty protocol). Instead we now fire ONE burst — CPR cursor +
    // OSC10/11 default colors + kitty keyboard flags + DA1 done-marker — under a
    // single deadline (dup tty + O_NONBLOCK + poll), warming the terminal, learning
    // the cursor position, and resolving keyboard-enhancement support in one pass.
    // The probe NEVER hangs: unanswered fields come back `None` and we degrade.
    let probe = app::terminal_probe::run(app::terminal_probe::DEFAULT_TIMEOUT);
    tracing::info!(
        cursor_position = probe.cursor_position.is_some(),
        default_colors = probe.default_colors.is_some(),
        keyboard_enhancement_supported = ?probe.keyboard_enhancement_supported,
        "batched startup terminal probe completed"
    );

    // Trust the probe's answer, and use the env-based fallback ONLY when the
    // probe was inconclusive. The probe distinguishes three states:
    //   Some(true)  — kitty flags seen: supported.
    //   Some(false) — DA1 answered but no kitty flags: DEFINITIVELY unsupported
    //                 (e.g. a kitty-family terminal reached through tmux/SSH that
    //                 does not forward the protocol).
    //   None        — nothing answered: unknown.
    // The old `unwrap_or(false) || env` collapsed Some(false) and None together,
    // so the env guess overrode a definitive "unsupported" — the composer then
    // advertised "shift+⏎ newline" while Shift+Enter actually collapsed to a bare
    // Enter and SUBMITTED. Trust Some(false); only guess from env on None. The
    // composer's newline hint derives from this same value, so it can't lie.
    let kbd_enhanced = match probe.keyboard_enhancement_supported {
        Some(supported) => supported,
        None => terminal_known_kitty_protocol(),
    };
    // Reliability vs. honesty are two separate decisions:
    //   * `kbd_enhanced` (above) drives the composer's newline HINT, so it stays
    //     conservative — it only claims "shift+⏎" when we KNOW the protocol works.
    //   * `should_push_enhancement_flags` decides whether to actually PUSH the
    //     flags, and pushes on an inconclusive probe (`None`) too. The push is a
    //     harmless no-op on terminals that ignore the kitty protocol (they drop
    //     the `CSI > u` sequence), so pushing optimistically recovers a reliable
    //     Shift+Enter newline on capable terminals whose reply the busy startup
    //     burst missed — WITHOUT ever making the hint lie. The exit pop is
    //     unconditional, so push/pop stay balanced.
    //
    // TERMINAL LIMITATION: genuinely legacy terminals (Apple Terminal, the VS
    // Code integrated terminal, plain xterm, and most tmux/SSH passthroughs)
    // cannot report Shift+Enter as a distinct key at all — it collapses to a bare
    // Enter no matter what flags we push. There Shift+Enter necessarily submits,
    // and the portable "insert newline" chords are Ctrl+J and the backslash-
    // continuation (a trailing "\" before Enter); see `app::key_normalize`. The
    // composer advertises the backslash affordance in that case.
    if should_push_enhancement_flags(probe.keyboard_enhancement_supported) {
        let _ = execute!(
            io::stdout(),
            PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
        );
    }
    tracing::info!(kbd_enhanced, "keyboard enhancement (Shift+Enter newline) status");

    // The burst above already sent a CPR (ESC[6n) and drained its response, so the
    // terminal is warmed up before ratatui's Viewport::Inline construction issues
    // its own DSR cursor query below. The inline-viewport creation still retries
    // (see below) as a final graceful fallback for stubborn launch contexts.
    let rows = app::frame_size::probe().rows;
    let viewport_h = compute_viewport_height(rows);

    // Create the inline viewport, retrying if the cursor query still times out
    // (intermittent DSR flakiness) instead of aborting the whole TUI.
    let mut terminal = None;
    let mut last_err = None;
    for attempt in 0..6u64 {
        match Terminal::with_options(
            crate::app::inline_backend::InlineBackend::new(io::stdout()),
            TerminalOptions {
                viewport: Viewport::Inline(viewport_h),
            },
        ) {
            Ok(t) => {
                terminal = Some(t);
                break;
            }
            Err(e) => {
                last_err = Some(e);
                std::thread::sleep(std::time::Duration::from_millis(40 * (attempt + 1)));
            }
        }
    }
    // If the inline viewport could not be built (the DSR cursor-position query
    // was dropped on every attempt — some terminals/launch contexts do this),
    // degrade gracefully to a full-screen terminal rather than aborting with a
    // "cursor position could not be read" error in the user's face. `Terminal::new`
    // does NOT query the cursor, so it always succeeds; the event loop's
    // viewport reconciliation takes over from there. No visible error, no hang.
    let terminal = match terminal {
        Some(t) => t,
        None => {
            error!(
                "inline viewport unavailable ({:?}); falling back to full-screen",
                last_err
            );
            Terminal::new(crate::app::inline_backend::InlineBackend::new(io::stdout()))?
        }
    };

    // Create tokio runtime
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;

    // Run the app
    runtime.block_on(async {
        let mut app = app::App::new(cfg, cli, kbd_enhanced).await?;
        app.run(terminal, viewport_h).await
    })
}

/// Terminals known to implement the kitty keyboard protocol (so Shift+Enter is
/// reported as a distinct key). Detected from `$TERM` / `$TERM_PROGRAM` / their
/// marker env vars, so a flaky runtime probe can't strand a capable terminal
/// without the protocol enabled.
fn terminal_known_kitty_protocol() -> bool {
    use std::env::var;
    let term = var("TERM").unwrap_or_default().to_ascii_lowercase();
    let prog = var("TERM_PROGRAM").unwrap_or_default().to_ascii_lowercase();
    term.contains("ghostty")
        || term.contains("kitty")
        || term.contains("foot")
        || term.contains("wezterm")
        || prog.contains("ghostty")
        || prog.contains("kitty")
        || prog.contains("wezterm")
        || var("KITTY_WINDOW_ID").is_ok()
        || var("GHOSTTY_RESOURCES_DIR").is_ok()
        || var("WEZTERM_PANE").is_ok()
}

/// Whether to push the kitty keyboard-enhancement flags (DISAMBIGUATE_ESCAPE_CODES)
/// so Shift+Enter is reported as a distinct `Enter+SHIFT` newline chord.
///
/// We push UNLESS the startup probe DEFINITIVELY reported the protocol
/// unsupported (`Some(false)`). A confirmed `Some(true)` obviously pushes; an
/// inconclusive `None` also pushes, optimistically, because the push is a
/// harmless no-op on terminals that ignore the protocol yet recovers Shift+Enter
/// on capable terminals whose reply the busy startup burst never saw. Kept as a
/// pure function so the policy is unit-testable without a live terminal.
fn should_push_enhancement_flags(probe: Option<bool>) -> bool {
    !matches!(probe, Some(false))
}

fn restore_terminal() -> Result<()> {
    let mut stdout = io::stdout();
    // Defensive: if a panic unwound between the paired BeginSynchronizedUpdate /
    // EndSynchronizedUpdate around a frame draw (event_loop), the terminal could
    // be left holding output. Close any open synchronized update first so the
    // shell never inherits a frozen screen.
    let _ = execute!(stdout, crossterm::terminal::EndSynchronizedUpdate);
    // Leave the alternate screen ONLY if we are actually on it (a crash inside a
    // modal, say). This used to be unconditional, and that was a real bug once
    // anything printed on exit: `LeaveAlternateScreen` (DECRST 1049) RESTORES
    // the cursor position saved by the matching `EnterAlternateScreen`, so an
    // UNPAIRED call — the normal case, since the app returns to the inline view
    // when the last dialog closes — teleported the cursor back to wherever the
    // boot-time Connecting screen had left it, near the top. Everything written
    // afterwards (the resume hint, then the shell's own prompt) landed on top of
    // the transcript. `app::alt_screen` tracks the real state, so the panic path
    // still recovers a terminal genuinely stuck on the alt screen.
    if app::alt_screen::is_active() {
        let _ = execute!(stdout, LeaveAlternateScreen);
    }
    let _ = execute!(stdout, PopKeyboardEnhancementFlags);
    let _ = execute!(stdout, DisableMouseCapture);
    // U-T11: stop focus reporting (paired with EnableFocusChange in setup) so the
    // shell never inherits a terminal that keeps emitting CSI I / CSI O.
    let _ = execute!(stdout, DisableFocusChange);
    let _ = execute!(stdout, DisableBracketedPaste);
    disable_raw_mode()?;
    // Land the shell prompt below the inline viewport instead of over it.
    let _ = write!(stdout, "\r\n");
    let _ = stdout.flush();
    Ok(())
}

#[cfg(test)]
mod keyboard_enhancement_tests {
    use super::should_push_enhancement_flags;

    #[test]
    fn pushes_on_confirmed_support() {
        assert!(should_push_enhancement_flags(Some(true)));
    }

    #[test]
    fn pushes_optimistically_on_inconclusive_probe() {
        // The busy-startup probe can miss the reply on a capable terminal; an
        // inconclusive None must still push so Shift+Enter is not stranded.
        assert!(should_push_enhancement_flags(None));
    }

    #[test]
    fn does_not_push_when_definitively_unsupported() {
        // Some(false) is a definitive "no" (e.g. legacy terminal / tmux drop);
        // pushing is pointless there and we respect the probe.
        assert!(!should_push_enhancement_flags(Some(false)));
    }
}
