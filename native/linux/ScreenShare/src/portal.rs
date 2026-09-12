use anyhow::{ensure, Context, Result};
use ashpd::desktop::{
    remote_desktop::{Axis, DeviceType, KeyState, RemoteDesktop},
    screencast::{CursorMode, Screencast, SourceType},
    PersistMode, Session,
};
use std::{collections::HashSet, os::fd::OwnedFd};

#[derive(Debug, PartialEq)]
pub enum Input {
    Key {
        symbol: u32,
        pressed: bool,
    },
    Pointer {
        mask: u8,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    },
}

pub struct Desktop {
    pub remote: RemoteDesktop<'static>,
    pub session: Session<'static, RemoteDesktop<'static>>,
    pub node: u32,
    logical_size: (i32, i32),
    keyboard: bool,
    pointer: bool,
    buttons: u8,
    keys: HashSet<u32>,
}

impl Desktop {
    /// Read-only availability check: no session, consent request, or capture.
    pub async fn preflight(allow_input: bool) -> Result<()> {
        let remote = RemoteDesktop::new()
            .await
            .context("remote_desktop_portal_unavailable")?;
        let cast = Screencast::new()
            .await
            .context("screencast_portal_unavailable")?;
        let devices = remote.available_device_types().await?;
        ensure!(
            !allow_input
                || (devices.contains(DeviceType::Keyboard)
                    && devices.contains(DeviceType::Pointer)),
            "portal_input_unavailable"
        );
        ensure!(
            cast.available_source_types()
                .await?
                .contains(SourceType::Monitor),
            "portal_monitor_unavailable"
        );
        ensure!(
            cast.available_cursor_modes()
                .await?
                .contains(CursorMode::Embedded),
            "portal_embedded_cursor_unavailable"
        );
        Ok(())
    }

    pub async fn request(allow_input: bool) -> Result<(Self, OwnedFd)> {
        let remote = RemoteDesktop::new()
            .await
            .context("remote_desktop_portal_unavailable")?;
        let cast = Screencast::new()
            .await
            .context("screencast_portal_unavailable")?;
        let session = remote.create_session().await?;
        // Connection loss closes the session even on errors before construction.
        let setup = async {
            remote
                .select_devices(
                    &session,
                    if allow_input {
                        DeviceType::Keyboard | DeviceType::Pointer
                    } else {
                        Default::default()
                    },
                    None,
                    PersistMode::DoNot,
                )
                .await?
                .response()?;
            cast.select_sources(
                &session,
                CursorMode::Embedded,
                SourceType::Monitor.into(),
                false,
                None,
                PersistMode::DoNot,
            )
            .await?
            .response()?;
            let response = remote.start(&session, None).await?.response()?;
            ensure!(
                !allow_input
                    || (response.devices().contains(DeviceType::Keyboard)
                        && response.devices().contains(DeviceType::Pointer)),
                "requested_input_not_granted"
            );
            let streams = response.streams().context("no_monitor_granted")?;
            ensure!(streams.len() == 1, "expected_one_monitor");
            let stream = &streams[0];
            let size = stream.size().context("logical_monitor_size_missing")?;
            ensure!(size.0 > 0 && size.1 > 0, "invalid_logical_monitor_size");
            let fd = cast.open_pipe_wire_remote(&session).await?;
            Ok::<_, anyhow::Error>((stream.pipe_wire_node_id(), size, response.devices(), fd))
        }
        .await;
        match setup {
            Ok((node, logical_size, devices, fd)) => Ok((
                Self {
                    remote,
                    session,
                    node,
                    logical_size,
                    keyboard: allow_input && devices.contains(DeviceType::Keyboard),
                    pointer: allow_input && devices.contains(DeviceType::Pointer),
                    buttons: 0,
                    keys: HashSet::new(),
                },
                fd,
            )),
            Err(error) => {
                let _ = session.close().await;
                Err(error)
            }
        }
    }

    pub async fn input(&mut self, input: Input) -> Result<()> {
        match input {
            Input::Key { symbol, pressed } if self.keyboard => {
                ensure!(symbol <= i32::MAX as u32, "invalid_keysym");
                ensure!(
                    !pressed || self.keys.len() < 256 || self.keys.contains(&symbol),
                    "pressed_key_limit"
                );
                self.remote
                    .notify_keyboard_keysym(&self.session, symbol as i32, state(pressed))
                    .await?;
                if pressed {
                    self.keys.insert(symbol);
                } else {
                    self.keys.remove(&symbol);
                }
            }
            Input::Pointer {
                mask,
                x,
                y,
                width,
                height,
            } if self.pointer => {
                let (x, y) = logical_point(x, y, width, height, self.logical_size)?;
                self.remote
                    .notify_pointer_motion_absolute(&self.session, self.node, x, y)
                    .await?;
                for (bit, button) in [(1, 272), (2, 274), (4, 273)] {
                    if mask & bit != self.buttons & bit {
                        self.remote
                            .notify_pointer_button(&self.session, button, state(mask & bit != 0))
                            .await?;
                        self.buttons = (self.buttons & !bit) | (mask & bit);
                    }
                }
                for (bit, axis, steps) in [
                    (8, Axis::Vertical, -1),
                    (16, Axis::Vertical, 1),
                    (32, Axis::Horizontal, -1),
                    (64, Axis::Horizontal, 1),
                ] {
                    if mask & bit != 0 && self.buttons & bit == 0 {
                        self.remote
                            .notify_pointer_axis_discrete(&self.session, axis, steps)
                            .await?;
                    }
                }
                self.buttons = mask;
            }
            _ => {} // A view-only consent response never grants input implicitly.
        }
        Ok(())
    }

    pub async fn close(&mut self) {
        for symbol in self.keys.drain() {
            let _ = self
                .remote
                .notify_keyboard_keysym(&self.session, symbol as i32, KeyState::Released)
                .await;
        }
        for (bit, button) in [(1, 272), (2, 274), (4, 273)] {
            if self.buttons & bit != 0 {
                let _ = self
                    .remote
                    .notify_pointer_button(&self.session, button, KeyState::Released)
                    .await;
            }
        }
        let _ = self.session.close().await;
    }
}

fn state(pressed: bool) -> KeyState {
    if pressed {
        KeyState::Pressed
    } else {
        KeyState::Released
    }
}

pub fn logical_point(
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    size: (i32, i32),
) -> Result<(f64, f64)> {
    ensure!(
        width > 0 && height > 0 && size.0 > 0 && size.1 > 0,
        "invalid_pointer_dimensions"
    );
    ensure!(x < width && y < height, "pointer_outside_stream");
    Ok((
        f64::from(x) * f64::from(size.0) / f64::from(width),
        f64::from(y) * f64::from(size.1) / f64::from(height),
    ))
}
