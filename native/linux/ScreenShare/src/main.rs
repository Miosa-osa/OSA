use anyhow::{bail, Context, Result};
use futures_util::StreamExt;
use osa_screen_capture_wayland::permission::{self, Mode};
use osa_screen_capture_wayland::{capture::Capture, portal::Desktop, rfb};
use std::{
    io::{Read, Write},
    time::Duration,
};
use tokio::{
    net::TcpListener,
    sync::{mpsc, oneshot, watch},
    time::timeout,
};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mode = permission::parse(&args.iter().map(String::as_str).collect::<Vec<_>>());
    let allow_input = match mode {
        Ok(Mode::Version) => {
            println!("osa-screen-capture-wayland {}", env!("CARGO_PKG_VERSION"));
            return;
        }
        Ok(Mode::Help) => {
            println!("Usage: osa-screen-capture-wayland [--read-only | --allow-input | --check | --version | --help]\nDefault is read-only with fresh monitor consent; stdin EOF stops sharing.\n--allow-input additionally requests fresh keyboard/pointer consent.\n--check tests prerequisites without requesting capture.");
            return;
        }
        Ok(Mode::Check) => match preflight(false).await {
            Ok(()) => {
                println!("READY=wayland_portal");
                return;
            }
            Err(error) => {
                eprintln!("ERROR=wayland_unavailable: {error}");
                std::process::exit(1);
            }
        },
        Ok(Mode::Share { allow_input }) => allow_input,
        _ => {
            eprintln!("ERROR=invalid_arguments");
            std::process::exit(64);
        }
    };
    // Set up owner EOF and signals before any portal call, including consent.
    let (owner_closed, owner) = oneshot::channel();
    std::thread::spawn(move || {
        let mut byte = [0];
        while let Ok(n) = std::io::stdin().read(&mut byte) {
            if n == 0 {
                break;
            }
        }
        let _ = owner_closed.send(());
    });
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("signal setup");
    let result = tokio::select! {
        result = run(allow_input) => result,
        _ = owner => Ok(()),
        _ = term.recv() => Ok(()),
        _ = tokio::signal::ctrl_c() => Ok(()),
    };
    // Runtime/process exit also releases D-Bus and PipeWire descriptors on
    // interrupted setup. No daemon, descendants, or restore tokens survive.
    if let Err(error) = result {
        eprintln!("ERROR=wayland_session_failed: {error}");
        std::process::exit(1);
    }
    std::process::exit(0);
}

async fn run(allow_input: bool) -> Result<()> {
    preflight(allow_input).await?;
    share(allow_input).await
}

async fn preflight(allow_input: bool) -> Result<()> {
    for variable in [
        "WAYLAND_DISPLAY",
        "XDG_RUNTIME_DIR",
        "DBUS_SESSION_BUS_ADDRESS",
    ] {
        if std::env::var(variable)
            .unwrap_or_default()
            .trim()
            .is_empty()
        {
            bail!("wayland_session_unavailable");
        }
    }
    Capture::preflight()?;
    timeout(Duration::from_secs(5), Desktop::preflight(allow_input))
        .await
        .context("portal_probe_timeout")??;
    Ok(())
}

async fn share(allow_input: bool) -> Result<()> {
    // Consent is always fresh and may take longer than ordinary process startup.
    let (mut desktop, fd) = timeout(Duration::from_secs(100), Desktop::request(allow_input))
        .await
        .context("consent_timeout")??;
    let result = async {
        let mut closed = desktop.session.receive_closed().await?;
        let (tx, mut frames) = watch::channel(None);
        let capture = Capture::start(fd, desktop.node, tx)?;
        let mut health = tokio::time::interval(Duration::from_millis(100));
        timeout(Duration::from_secs(15), async {
            loop {
                tokio::select! {
                    _ = closed.next() => bail!("portal_session_closed"),
                    _ = health.tick() => capture.check()?,
                    result = frames.changed() => {
                        result?;
                        if frames.borrow().is_some() { return Ok::<_, anyhow::Error>(()); }
                    }
                }
            }
        }).await.context("first_frame_timeout")??;
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await?;
        println!("PORT={}", listener.local_addr()?.port());
        std::io::stdout().flush()?;
        let (socket, _) = tokio::select! {
            _ = closed.next() => bail!("portal_session_closed"),
            result = timeout(Duration::from_secs(30), listener.accept()) => result.context("viewer_timeout")??,
        };
        drop(listener); // Exactly one viewer. A reconnect requires fresh consent.
        let (input_tx, mut input_rx) = mpsc::channel(64);
        let server = rfb::serve(socket, frames, input_tx);
        tokio::pin!(server);
        loop {
            tokio::select! {
                result = &mut server => return result,
                _ = closed.next() => bail!("portal_session_closed"),
                _ = health.tick() => capture.check()?,
                Some(input) = input_rx.recv() => {
                    timeout(Duration::from_secs(2), desktop.input(input)).await.context("portal_input_timeout")??;
                }
            }
        }
    }.await;
    let _ = timeout(Duration::from_secs(2), desktop.close()).await;
    result
}
