use osa_screen_capture_wayland::rfb::PixelFormat;

#[test]
fn invalid_pixel_shifts_are_rejected_before_encoding() {
    let mut bytes = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0];
    bytes[10] = 32;
    assert!(PixelFormat::parse(bytes).is_err());
}

#[test]
fn pixel_conversion_supports_rgb565_and_big_endian() {
    let format =
        PixelFormat::parse([16, 16, 1, 1, 0, 31, 0, 63, 0, 31, 11, 5, 0, 0, 0, 0]).unwrap();
    let mut row = vec![];
    format.encode_row(&[0, 0, 255, 0, 255, 255, 255, 0], &mut row);
    assert_eq!(row, [0xf8, 0, 0xff, 0xff]);
}

#[test]
fn overlapping_and_color_map_formats_are_rejected() {
    let mut bytes = osa_screen_capture_wayland::rfb::DEFAULT_FORMAT;
    bytes[11] = bytes[10];
    assert!(PixelFormat::parse(bytes).is_err());
    bytes = osa_screen_capture_wayland::rfb::DEFAULT_FORMAT;
    bytes[3] = 0;
    assert!(PixelFormat::parse(bytes).is_err());
}

// Fixture pixels exercise only the wire encoder. The executable has no fake
// capture mode and these tests never contact a portal, compositor, or PipeWire.
#[tokio::test]
async fn viewer_receives_pixels_and_input_reaches_the_portal_seam() {
    use osa_screen_capture_wayland::{frame::Frame, portal::Input, rfb};
    use std::sync::Arc;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        sync::{mpsc, watch},
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut viewer = TcpStream::connect(listener.local_addr().unwrap())
        .await
        .unwrap();
    let (socket, _) = listener.accept().await.unwrap();
    let frame = Frame::from_bgrx(1, 1, 4, &[11, 22, 33, 0]).unwrap();
    let (_frames, rx) = watch::channel(Some(Arc::new(frame)));
    let (tx, mut inputs) = mpsc::channel(4);
    let task = tokio::spawn(rfb::serve(socket, rx, tx));
    let mut version = [0; 12];
    viewer.read_exact(&mut version).await.unwrap();
    assert_eq!(&version, b"RFB 003.008\n");
    viewer.write_all(&version).await.unwrap();
    assert_eq!(viewer.read_u16().await.unwrap(), 257);
    viewer.write_u8(1).await.unwrap();
    assert_eq!(viewer.read_u32().await.unwrap(), 0);
    viewer.write_u8(1).await.unwrap();
    assert_eq!(viewer.read_u16().await.unwrap(), 1);
    assert_eq!(viewer.read_u16().await.unwrap(), 1);
    let mut format = [0; 16];
    viewer.read_exact(&mut format).await.unwrap();
    assert_eq!(format, rfb::DEFAULT_FORMAT);
    let length = viewer.read_u32().await.unwrap() as usize;
    let mut name = vec![0; length];
    viewer.read_exact(&mut name).await.unwrap();
    // Raw remains a mandatory RFB fallback even if only Tight is advertised.
    viewer.write_all(&[2, 0, 0, 1, 0, 0, 0, 7]).await.unwrap();
    viewer
        .write_all(&[3, 0, 0, 0, 0, 0, 0, 1, 0, 1])
        .await
        .unwrap();
    let mut update = [0; 20];
    viewer.read_exact(&mut update).await.unwrap();
    assert_eq!(&update[16..], &[11, 22, 33, 0]);
    viewer.write_all(&[4, 1, 0, 0, 0, 0, 0, 65]).await.unwrap();
    assert_eq!(
        inputs.recv().await.unwrap(),
        Input::Key {
            symbol: 65,
            pressed: true
        }
    );
    // An excessive clipboard payload is rejected without reading/allocating it.
    viewer
        .write_all(&[6, 0, 0, 0, 0xff, 0xff, 0xff, 0xff])
        .await
        .unwrap();
    assert!(task
        .await
        .unwrap()
        .unwrap_err()
        .to_string()
        .contains("clipboard_limit"));
}
