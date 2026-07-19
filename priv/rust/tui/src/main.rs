use anyhow::Result;
use crossterm::{
    event::{
        DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
        KeyboardEnhancementFlags, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
    },
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, supports_keyboard_enhancement, LeaveAlternateScreen},
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
    // The single `supports_keyboard_enhancement()` probe races OSA's busy startup
    // (bracketed-paste enable + the cursor-position priming burst below) and can
    // flake to `false` on the first try even on terminals that DO support the
    // kitty keyboard protocol — which then silently breaks Shift+Enter (it
    // collapses to a bare Enter and submits). Two hardening steps:
    //   1. Retry the probe a few times before giving up.
    //   2. Trust terminals we KNOW implement the protocol (Ghostty/Kitty/WezTerm/
    //      foot) even if the probe never answers — pushing the flag is harmless on
    //      any terminal (unsupported ones ignore the CSI sequence).
    let kbd_enhanced = {
        let probed = (0..5).any(|i| {
            if i > 0 {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            matches!(supports_keyboard_enhancement(), Ok(true))
        });
        probed || terminal_known_kitty_protocol()
    };
    if kbd_enhanced {
        let _ = execute!(
            io::stdout(),
            PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
        );
    }
    tracing::info!(kbd_enhanced, "keyboard enhancement (Shift+Enter newline) status");

    // ratatui's Viewport::Inline queries the terminal for the cursor position at
    // construction (a DSR request). Some terminals/launch contexts drop the very
    // first query and it times out ("cursor position could not be read"), which
    // aborts startup entirely. Prime it first: retry the query until the terminal
    // actually answers, so ratatui's query lands on a warmed-up terminal.
    for _ in 0..40 {
        if crossterm::cursor::position().is_ok() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }

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
