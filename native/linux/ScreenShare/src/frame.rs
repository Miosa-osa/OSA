use anyhow::{ensure, Result};

/// Packed BGRX, with no compositor padding or uninitialized alpha bytes.
#[derive(Debug)]
pub struct Frame {
    pub width: u16,
    pub height: u16,
    pub pixels: Vec<u8>,
}

impl Frame {
    pub fn from_bgrx(width: u32, height: u32, stride: usize, data: &[u8]) -> Result<Self> {
        ensure!(
            width > 0 && height > 0 && width <= 8192 && height <= 8192,
            "frame_dimensions"
        );
        ensure!(
            u64::from(width) * u64::from(height) <= 16_777_216,
            "frame_limit"
        );
        let row = width as usize * 4;
        ensure!(stride >= row, "frame_stride");
        let required = stride
            .checked_mul(height as usize - 1)
            .and_then(|n| n.checked_add(row));
        ensure!(required.is_some_and(|n| n <= data.len()), "frame_truncated");
        let mut pixels = Vec::with_capacity(row * height as usize);
        for y in 0..height as usize {
            for pixel in data[y * stride..y * stride + row].as_chunks::<4>().0 {
                pixels.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 0]);
            }
        }
        Ok(Self {
            width: width as u16,
            height: height as u16,
            pixels,
        })
    }
}
