//! Single-client RFB 3.8, raw encoding. All peer-controlled allocations bounded.
use crate::{frame::Frame, portal::Input};
use anyhow::{bail, ensure, Context, Result};
use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::{mpsc, watch},
    time::timeout,
};

pub const DEFAULT_FORMAT: [u8; 16] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0];

pub struct PixelFormat {
    bytes: usize,
    big_endian: bool,
    maximum: [u32; 3],
    shift: [u8; 3],
}

impl PixelFormat {
    pub fn parse(value: [u8; 16]) -> Result<Self> {
        ensure!(
            matches!(value[0], 16 | 32) && value[1] > 0 && value[1] <= value[0],
            "pixel_depth"
        );
        ensure!(value[2] <= 1 && value[3] == 1, "true_color_required");
        let maximum = [
            u16::from_be_bytes([value[4], value[5]]) as u32,
            u16::from_be_bytes([value[6], value[7]]) as u32,
            u16::from_be_bytes([value[8], value[9]]) as u32,
        ];
        let shift = [value[10], value[11], value[12]];
        let mut occupied = 0u64;
        let mut bits = 0;
        for (max, shift) in maximum.iter().zip(shift) {
            ensure!(
                *max > 0 && (*max + 1).is_power_of_two() && shift < value[0],
                "pixel_mask"
            );
            let mask = u64::from(*max) << shift;
            ensure!(
                mask < (1u64 << value[0]) && occupied & mask == 0,
                "pixel_overlap"
            );
            occupied |= mask;
            bits += max.count_ones();
        }
        ensure!(bits <= u32::from(value[1]), "pixel_depth_mask");
        Ok(Self {
            bytes: (value[0] / 8) as usize,
            big_endian: value[2] == 1,
            maximum,
            shift,
        })
    }

    pub fn encode_row(&self, bgrx: &[u8], output: &mut Vec<u8>) {
        output.clear();
        for pixel in bgrx.as_chunks::<4>().0 {
            let rgb = [pixel[2], pixel[1], pixel[0]];
            let value = (0..3).fold(0u32, |value, i| {
                value | ((u32::from(rgb[i]) * self.maximum[i] / 255) << self.shift[i])
            });
            let bytes = if self.big_endian {
                value.to_be_bytes()
            } else {
                value.to_le_bytes()
            };
            output.extend_from_slice(if self.big_endian {
                &bytes[4 - self.bytes..]
            } else {
                &bytes[..self.bytes]
            });
        }
    }
}

/// The caller owns session teardown on ANY return, including malformed input.
pub async fn serve(
    mut socket: TcpStream,
    mut frames: watch::Receiver<Option<Arc<Frame>>>,
    input: mpsc::Sender<Input>,
) -> Result<()> {
    socket.set_nodelay(true)?;
    let (screen_width, screen_height) = {
        let current = frames.borrow();
        let frame = current.as_ref().context("no_real_frame")?;
        (frame.width, frame.height)
    };
    timeout(Duration::from_secs(10), async {
        socket.write_all(b"RFB 003.008\n").await?;
        let mut version = [0; 12];
        socket.read_exact(&mut version).await?;
        ensure!(&version == b"RFB 003.008\n", "rfb_version");
        socket.write_all(&[1, 1]).await?;
        ensure!(socket.read_u8().await? == 1, "rfb_security");
        socket.write_u32(0).await?;
        socket.read_u8().await?;
        socket.write_u16(screen_width).await?;
        socket.write_u16(screen_height).await?;
        socket.write_all(&DEFAULT_FORMAT).await?;
        let name = b"OSA consented Wayland monitor";
        socket.write_u32(name.len() as u32).await?;
        socket.write_all(name).await?;
        Ok::<_, anyhow::Error>(())
    })
    .await
    .context("rfb_handshake_timeout")??;

    let mut format = PixelFormat::parse(DEFAULT_FORMAT)?;
    loop {
        // The entire message is bounded by one deadline, not reset per byte.
        timeout(Duration::from_secs(60), async {
            match socket.read_u8().await? {
                0 => {
                    let mut padding = [0; 3];
                    socket.read_exact(&mut padding).await?;
                    let mut bytes = [0; 16];
                    socket.read_exact(&mut bytes).await?;
                    format = PixelFormat::parse(bytes)?;
                }
                2 => {
                    socket.read_u8().await?;
                    let count = socket.read_u16().await?;
                    ensure!(count <= 256, "encoding_limit");
                    for _ in 0..count {
                        socket.read_i32().await?;
                    }
                    // RFB specifies raw as the mandatory fallback even if omitted.
                }
                3 => {
                    socket.read_u8().await?; // incremental requests may receive a full rectangle
                    let x = socket.read_u16().await?;
                    let y = socket.read_u16().await?;
                    let width = socket.read_u16().await?;
                    let height = socket.read_u16().await?;
                    let frame = frames
                        .borrow_and_update()
                        .clone()
                        .context("capture_ended")?;
                    ensure!(
                        frame.width == screen_width && frame.height == screen_height,
                        "monitor_resized_reconnect_required"
                    );
                    ensure!(
                        u32::from(x) + u32::from(width) <= u32::from(frame.width)
                            && u32::from(y) + u32::from(height) <= u32::from(frame.height),
                        "rectangle_outside_stream"
                    );
                    socket.write_all(&[0, 0]).await?;
                    socket
                        .write_u16(if width == 0 || height == 0 { 0 } else { 1 })
                        .await?;
                    if width != 0 && height != 0 {
                        socket.write_u16(x).await?;
                        socket.write_u16(y).await?;
                        socket.write_u16(width).await?;
                        socket.write_u16(height).await?;
                        socket.write_i32(0).await?;
                        let mut row = Vec::with_capacity(width as usize * format.bytes);
                        for line in y..y + height {
                            let offset = (line as usize * frame.width as usize + x as usize) * 4;
                            format.encode_row(
                                &frame.pixels[offset..offset + width as usize * 4],
                                &mut row,
                            );
                            socket.write_all(&row).await?;
                        }
                    }
                    // Bound a client's ability to repeatedly encode the same frame.
                    tokio::time::sleep(Duration::from_millis(66)).await;
                }
                4 => {
                    let pressed = socket.read_u8().await?;
                    ensure!(pressed <= 1, "invalid_key_state");
                    socket.read_u16().await?;
                    let symbol = socket.read_u32().await?;
                    input
                        .send(Input::Key {
                            symbol,
                            pressed: pressed == 1,
                        })
                        .await?;
                }
                5 => {
                    let mask = socket.read_u8().await?;
                    let x = socket.read_u16().await?;
                    let y = socket.read_u16().await?;
                    ensure!(
                        x < screen_width && y < screen_height,
                        "pointer_outside_stream"
                    );
                    input
                        .send(Input::Pointer {
                            mask,
                            x,
                            y,
                            width: screen_width,
                            height: screen_height,
                        })
                        .await?;
                }
                6 => {
                    let mut padding = [0; 3];
                    socket.read_exact(&mut padding).await?;
                    let length = socket.read_u32().await?;
                    ensure!(length <= 65_536, "clipboard_limit");
                    // Clipboard permissions are not requested. Consume and discard.
                    let mut remaining = length as usize;
                    let mut scratch = [0; 1024];
                    while remaining > 0 {
                        let size = remaining.min(scratch.len());
                        socket.read_exact(&mut scratch[..size]).await?;
                        remaining -= size;
                    }
                }
                _ => bail!("unsupported_rfb_message"),
            }
            Ok::<_, anyhow::Error>(())
        })
        .await
        .context("rfb_message_timeout")??;
    }
}
