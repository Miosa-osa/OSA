use osa_screen_capture_wayland::frame::Frame;

#[test]
fn capture_rows_exclude_padding_and_preserve_pixels() {
    let frame = Frame::from_bgrx(1, 2, 8, &[1, 2, 3, 0, 99, 99, 99, 99, 4, 5, 6, 0]).unwrap();
    assert_eq!(frame.pixels, [1, 2, 3, 0, 4, 5, 6, 0]);
}

#[test]
fn capture_rejects_invalid_and_oversized_frames_without_allocating() {
    for (w, h, stride) in [
        (0, 1, 4),
        (1, 0, 4),
        (8193, 1, 32772),
        (8192, 8192, 32768),
        (2, 1, 4),
        (1, 2, usize::MAX),
    ] {
        assert!(Frame::from_bgrx(w, h, stride, &[]).is_err());
    }
    assert!(Frame::from_bgrx(1, 1, 4, &[1, 2, 3]).is_err());
}

#[test]
fn unused_pixel_byte_is_not_exposed_to_the_viewer() {
    assert_eq!(
        Frame::from_bgrx(1, 1, 4, &[1, 2, 3, 99]).unwrap().pixels,
        [1, 2, 3, 0]
    );
}
