use anyhow::Result;
use std::sync::OnceLock;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

use crate::config::cli::Cli;

// Keep the guard alive for the program's lifetime
static LOG_GUARD: OnceLock<WorkerGuard> = OnceLock::new();

pub fn init(cli: &Cli) -> Result<()> {
    let log_dir = cli.log_dir();
    std::fs::create_dir_all(&log_dir)?;

    let file_appender = tracing_appender::rolling::daily(&log_dir, "tui.log");
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);

    let env_filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        if cli.dev {
            EnvFilter::new("debug")
        } else {
            EnvFilter::new("info")
        }
    });

    tracing_subscriber::registry()
        .with(
            fmt::layer()
                .with_writer(non_blocking)
                .with_ansi(false)
                .with_target(true)
                .with_thread_ids(true)
                .with_file(true)
                .with_line_number(true),
        )
        .with(env_filter)
        .init();

    LOG_GUARD.set(guard).ok();

    tracing::info!("OSA TUI starting (version {})", env!("CARGO_PKG_VERSION"));
    Ok(())
}
