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

/// Inline viewport height for the live region:
/// preview cap (8) + thinking/activity (1) + status (1) + input reserve (2+).
pub const LIVE_H_BASE: u16 = 12;

/// Clamp the inline viewport height to something sane for the terminal size.
fn compute_viewport_height(term_rows: u16) -> u16 {
    LIVE_H_BASE.min(term_rows.saturating_sub(1)).max(4)
}

fn run(cli: config::cli::Cli) -> Result<()> {
    // Load config
    let cfg = config::Config::load(&cli)?;

    // Setup terminal — NO alt screen, NO mouse capture: the host terminal owns
    // scrollback and native wheel scrolling. Only bracketed paste is enabled so
    // the Ctrl+V / paste flow keeps working.
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnableBracketedPaste)?;
    let backend = CrosstermBackend::new(stdout);
    let (_cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    let viewport_h = compute_viewport_height(rows);
    let terminal = Terminal::with_options(
        backend,
        TerminalOptions {
            viewport: Viewport::Inline(viewport_h),
        },
    )?;

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
