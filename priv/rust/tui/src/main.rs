use anyhow::Result;
use crossterm::{
    event::{
        DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste,
        KeyboardEnhancementFlags, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
    },
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, LeaveAlternateScreen},
};
use ratatui::{prelude::*, Terminal, TerminalOptions, Viewport};
use std::io::{self, Write};
use tracing::error;

mod a11y;
mod app;
mod client;
mod components;
mod config;
mod event;
mod logging;
mod render;
mod style;
mod view;
mod dialogs;
mod util;
mod tools;
mod voice;

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

    result
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

fn run(cli: config::cli::Cli) -> Result<()> {
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
    if kbd_enhanced {
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
    let (_cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    let viewport_h = compute_viewport_height(rows);

    // Create the inline viewport, retrying if the cursor query still times out
    // (intermittent DSR flakiness) instead of aborting the whole TUI.
    let mut terminal = None;
    let mut last_err = None;
    for attempt in 0..6u64 {
        match Terminal::with_options(
            CrosstermBackend::new(io::stdout()),
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
            Terminal::new(CrosstermBackend::new(io::stdout()))?
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

fn restore_terminal() -> Result<()> {
    let mut stdout = io::stdout();
    // Defensive: if a panic unwound between the paired BeginSynchronizedUpdate /
    // EndSynchronizedUpdate around a frame draw (event_loop), the terminal could
    // be left holding output. Close any open synchronized update first so the
    // shell never inherits a frozen screen.
    let _ = execute!(stdout, crossterm::terminal::EndSynchronizedUpdate);
    // Best-effort: if we crashed while in a modal we may still be on the alt screen.
    let _ = execute!(stdout, LeaveAlternateScreen);
    let _ = execute!(stdout, PopKeyboardEnhancementFlags);
    let _ = execute!(stdout, DisableMouseCapture);
    let _ = execute!(stdout, DisableBracketedPaste);
    disable_raw_mode()?;
    // Land the shell prompt below the inline viewport instead of over it.
    let _ = write!(stdout, "\r\n");
    let _ = stdout.flush();
    Ok(())
}
