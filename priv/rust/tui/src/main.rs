use anyhow::Result;
use crossterm::{
    event::{DisableBracketedPaste, EnableBracketedPaste},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, LeaveAlternateScreen},
};
use ratatui::{prelude::*, Terminal, TerminalOptions, Viewport};
use std::io::{self, Write};
use tracing::error;

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

/// Inline viewport height for the live region (Claude-Code chrome). Sized to fit:
///   streaming preview (1) + thinking/activity (1) + ctx-hint (1) +
///   input box (3: top divider + text + bottom divider) + status region
///   (2: status line + permission/shell line) = 8 rows minimum.
/// Finished replies go to native scrollback, so the live preview stays compact.
pub const LIVE_H_BASE: u16 = 8;

/// Clamp the inline viewport height to something sane for the terminal size.
/// Never exceed `term_rows - 1` so tiny terminals don't overflow the viewport.
fn compute_viewport_height(term_rows: u16) -> u16 {
    LIVE_H_BASE.min(term_rows.saturating_sub(1).max(1))
}

fn run(cli: config::cli::Cli) -> Result<()> {
    // Load config
    let cfg = config::Config::load(&cli)?;

    // Setup terminal — NO alt screen, NO mouse capture: the host terminal owns
    // scrollback and native wheel scrolling. Only bracketed paste is enabled so
    // the Ctrl+V / paste flow keeps working.
    enable_raw_mode()?;
    execute!(io::stdout(), EnableBracketedPaste)?;

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
    let terminal = match terminal {
        Some(t) => t,
        None => {
            return Err(anyhow::anyhow!(
                "failed to initialize inline terminal after retries: {:?}",
                last_err
            ))
        }
    };

    // Create tokio runtime
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;

    // Run the app
    runtime.block_on(async {
        let mut app = app::App::new(cfg, cli).await?;
        app.run(terminal, viewport_h).await
    })
}

fn restore_terminal() -> Result<()> {
    let mut stdout = io::stdout();
    // Best-effort: if we crashed while in a modal we may still be on the alt screen.
    let _ = execute!(stdout, LeaveAlternateScreen);
    let _ = execute!(stdout, DisableBracketedPaste);
    disable_raw_mode()?;
    // Land the shell prompt below the inline viewport instead of over it.
    let _ = write!(stdout, "\r\n");
    let _ = stdout.flush();
    Ok(())
}
