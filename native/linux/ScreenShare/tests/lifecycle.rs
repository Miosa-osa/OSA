use std::{
    process::{Command, Stdio},
    time::{Duration, Instant},
};

#[test]
fn version_does_not_require_a_desktop() {
    let output = Command::new(env!("CARGO_BIN_EXE_osa-screen-capture-wayland"))
        .arg("--version")
        .env_clear()
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).starts_with("osa-screen-capture-wayland "));
}

#[test]
fn unknown_arguments_cannot_open_a_capture_session() {
    let output = Command::new(env!("CARGO_BIN_EXE_osa-screen-capture-wayland"))
        .arg("--unknown")
        .env_clear()
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(64));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("PORT="));
}

#[test]
fn missing_portal_or_owner_eof_never_announces_a_port_or_leaves_a_process() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_osa-screen-capture-wayland"))
        .env_clear()
        .env("WAYLAND_DISPLAY", "test-only")
        .env("XDG_RUNTIME_DIR", "/tmp")
        .env(
            "DBUS_SESSION_BUS_ADDRESS",
            "unix:path=/nonexistent-osa-test-bus",
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    drop(child.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() {
        if Instant::now() > deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("owner EOF did not terminate helper");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let output = child.wait_with_output().unwrap();
    assert!(!String::from_utf8_lossy(&output.stdout).contains("PORT="));
}
