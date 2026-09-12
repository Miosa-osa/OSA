use osa_screen_capture_wayland::portal::logical_point;

#[test]
fn hidpi_input_uses_portal_logical_coordinates() {
    assert_eq!(
        logical_point(1920, 1080, 3840, 2160, (1920, 1080)).unwrap(),
        (960.0, 540.0)
    );
    assert!(logical_point(3840, 0, 3840, 2160, (1920, 1080)).is_err());
    assert!(logical_point(0, 0, 0, 0, (1920, 1080)).is_err());
}
