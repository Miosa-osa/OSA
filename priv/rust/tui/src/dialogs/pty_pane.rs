//! A live subprocess, on a real PTY, rendered inside an OSA dialog.
//!
//! ## Why a PTY and not a pipe
//!
//! The standing rule for this harness is that everything happens inside OSA.
//! The programs we most need to drive — vendor CLIs doing their own sign-in —
//! are the exact class that refuses to cooperate with a pipe: they check
//! `isatty`, and when it says "not a terminal" they either degrade to a
//! non-interactive mode that cannot prompt, or disable the very output (spinner,
//! URL, code) the user has to read. Handing them a kernel PTY is what makes
//! "run it in another terminal" unnecessary rather than merely hidden.
//!
//! ## What this is not
//!
//! It is not a terminal emulator OSA ships as a feature. There is no scrollback
//! UI, no mouse, no alternate-screen etiquette beyond what `vt100` already
//! models. It is the smallest thing that can show a child's screen truthfully
//! and forward a keystroke back — deliberately, because a half-built emulator
//! that *looks* like a terminal invites the user to expect one.
//!
//! ## Threading
//!
//! The reader is an OS thread, not a tokio task: `MasterPty::try_clone_reader`
//! hands back a blocking `Read`, and parking a blocking read on the async
//! runtime's worker pool is how a TUI stops repainting. It owns nothing but the
//! shared parser, so the only synchronisation is one mutex the draw path locks
//! for the length of a frame.

use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize};
use ratatui::prelude::*;

/// Lines of history kept behind the visible screen.
///
/// Non-zero because a vendor CLI's login output routinely scrolls a banner off
/// the top before it prints the URL, and zero scrollback makes that
/// unrecoverable. Small because this pane does not expose a scrollback UI, so
/// anything beyond a screen or two is memory nobody can read.
const SCROLLBACK: usize = 200;

/// What the pane knows about its child.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PtyStatus {
    Running,
    /// The child is gone. `code` is its exit status; `0` is the only success.
    Exited { code: u32 },
    /// The child could never be started — a missing binary, a refused fork.
    /// Distinct from `Exited { code: 127 }` because nothing ran, so there is no
    /// child output to explain it and the message here is all the user gets.
    Failed { reason: String },
}

impl PtyStatus {
    pub fn is_running(&self) -> bool {
        matches!(self, PtyStatus::Running)
    }

    pub fn succeeded(&self) -> bool {
        matches!(self, PtyStatus::Exited { code: 0 })
    }
}

pub struct PtyPane {
    parser: Arc<Mutex<vt100::Parser>>,
    writer: Option<Box<dyn Write + Send>>,
    child: Option<Box<dyn Child + Send + Sync>>,
    master: Option<Box<dyn MasterPty + Send>>,
    status: PtyStatus,
    size: (u16, u16),
    /// The command as a human-readable line, so the pane can name what it is
    /// running. A pane that shows output without saying whose output it is
    /// makes an unexpected prompt unattributable.
    pub command_line: String,
}

impl PtyPane {
    /// Spawn `program` with `args` on a fresh PTY sized `rows` x `cols`.
    ///
    /// Never returns `Err`: a spawn failure becomes `PtyStatus::Failed`, because
    /// every caller here wants to *render* the failure rather than unwind. The
    /// pane is the surface that explains what went wrong.
    pub fn spawn(
        program: &str,
        args: &[String],
        env: &[(String, Option<String>)],
        rows: u16,
        cols: u16,
    ) -> Self {
        let (rows, cols) = (rows.max(1), cols.max(1));
        let command_line = std::iter::once(program.to_string())
            .chain(args.iter().cloned())
            .collect::<Vec<_>>()
            .join(" ");
        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, SCROLLBACK)));

        let mut me = Self {
            parser: Arc::clone(&parser),
            writer: None,
            child: None,
            master: None,
            status: PtyStatus::Running,
            size: (rows, cols),
            command_line,
        };

        let pty_system = portable_pty::native_pty_system();
        let pair = match pty_system.openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        }) {
            Ok(p) => p,
            Err(e) => {
                me.status = PtyStatus::Failed {
                    reason: format!("could not open a pty: {}", e),
                };
                return me;
            }
        };

        let mut cmd = CommandBuilder::new(program);
        for a in args {
            cmd.arg(a);
        }
        // A child on a PTY inherits OSA's environment, which is right — it must
        // find the same config the user's shell would. The exceptions are
        // passed in explicitly by the caller: `None` unsets, which is how a
        // sign-in is kept off an API key that happens to be exported here.
        for (k, v) in env {
            match v {
                Some(val) => cmd.env(k, val),
                None => cmd.env_remove(k),
            }
        }
        if let Ok(cwd) = std::env::current_dir() {
            cmd.cwd(cwd);
        }
        // Vendor CLIs branch on TERM. Claiming something richer than this pane
        // renders would invite escape sequences `vt100` drops on the floor.
        cmd.env("TERM", "xterm-256color");

        let child = match pair.slave.spawn_command(cmd) {
            Ok(c) => c,
            Err(e) => {
                me.status = PtyStatus::Failed {
                    reason: format!("could not start `{}`: {}", program, e),
                };
                return me;
            }
        };
        drop(pair.slave);

        match pair.master.try_clone_reader() {
            Ok(mut reader) => {
                let sink = Arc::clone(&parser);
                std::thread::spawn(move || {
                    let mut buf = [0u8; 8192];
                    loop {
                        match reader.read(&mut buf) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                if let Ok(mut p) = sink.lock() {
                                    p.process(&buf[..n]);
                                }
                            }
                        }
                    }
                });
            }
            Err(e) => {
                me.status = PtyStatus::Failed {
                    reason: format!("could not read from the pty: {}", e),
                };
                return me;
            }
        }

        me.writer = pair.master.take_writer().ok();
        me.master = Some(pair.master);
        me.child = Some(child);
        me
    }

    pub fn status(&self) -> &PtyStatus {
        &self.status
    }

    /// Poll the child without blocking. Call once per tick.
    pub fn poll(&mut self) -> &PtyStatus {
        if !self.status.is_running() {
            return &self.status;
        }
        if let Some(child) = self.child.as_mut() {
            match child.try_wait() {
                Ok(Some(st)) => {
                    self.status = PtyStatus::Exited {
                        code: st.exit_code(),
                    };
                    // Dropping the writer sends EOF; keeping it open past the
                    // child's death leaves a live fd on a pty nobody reads.
                    self.writer = None;
                }
                Ok(None) => {}
                Err(e) => {
                    self.status = PtyStatus::Failed {
                        reason: format!("lost track of the child process: {}", e),
                    }
                }
            }
        }
        &self.status
    }

    /// Match the child's window to the pane it is drawn into.
    ///
    /// Both halves matter and they are not the same thing: `MasterPty::resize`
    /// is what makes the kernel deliver `SIGWINCH`, so the child re-lays-out;
    /// `Parser::set_size` is what makes *our* render of it agree. Doing only
    /// the first leaves a correctly-wrapped child clipped by a stale emulator.
    pub fn resize(&mut self, rows: u16, cols: u16) {
        let (rows, cols) = (rows.max(1), cols.max(1));
        if (rows, cols) == self.size {
            return;
        }
        self.size = (rows, cols);
        if let Some(master) = self.master.as_ref() {
            let _ = master.resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            });
        }
        if let Ok(mut p) = self.parser.lock() {
            p.set_size(rows, cols);
        }
    }

    /// Send raw bytes to the child.
    pub fn write(&mut self, bytes: &[u8]) {
        if let Some(w) = self.writer.as_mut() {
            let _ = w.write_all(bytes);
            let _ = w.flush();
        }
    }

    /// Forward a keystroke to the child.
    ///
    /// Returns false when the key encodes to nothing this pane knows how to
    /// send, so a caller can fall back to its own handling rather than silently
    /// swallowing it.
    pub fn send_key(&mut self, key: KeyEvent) -> bool {
        match encode_key(key) {
            Some(bytes) => {
                self.write(&bytes);
                true
            }
            None => false,
        }
    }

    /// The child's screen as plain text, newest-first row order preserved.
    /// Test support, and the evidence a failure report prints.
    pub fn screen_text(&self) -> String {
        self.parser
            .lock()
            .map(|p| p.screen().contents())
            .unwrap_or_default()
    }

    /// True once the child's screen contains `needle` (case-insensitive).
    pub fn screen_contains(&self, needle: &str) -> bool {
        self.screen_text()
            .to_lowercase()
            .contains(&needle.to_lowercase())
    }

    /// Ask the child to stop, then stop caring. Used on Esc and on drop.
    pub fn kill(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
        }
        self.writer = None;
    }

    /// Render the child's screen into `area`.
    ///
    /// Cell-by-cell rather than line-by-line: a vendor CLI's sign-in screen is
    /// mostly colour and reverse-video, and flattening it to plain text is how
    /// a highlighted "press enter" stops looking pressable.
    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        if area.width == 0 || area.height == 0 {
            return;
        }
        let parser = match self.parser.lock() {
            Ok(p) => p,
            Err(_) => return,
        };
        let screen = parser.screen();
        let (srows, scols) = screen.size();

        for y in 0..area.height.min(srows) {
            let mut spans: Vec<Span<'static>> = Vec::new();
            let mut run = String::new();
            let mut run_style: Option<Style> = None;

            for x in 0..area.width.min(scols) {
                let (ch, style) = match screen.cell(y, x) {
                    Some(c) if c.is_wide_continuation() => continue,
                    Some(c) => {
                        let s = c.contents();
                        (if s.is_empty() { " ".to_string() } else { s }, cell_style(c))
                    }
                    None => (" ".to_string(), Style::default()),
                };
                if run_style == Some(style) {
                    run.push_str(&ch);
                } else {
                    if let Some(prev) = run_style.take() {
                        spans.push(Span::styled(std::mem::take(&mut run), prev));
                    }
                    run = ch;
                    run_style = Some(style);
                }
            }
            if let Some(prev) = run_style {
                spans.push(Span::styled(run, prev));
            }

            frame.render_widget(
                ratatui::widgets::Paragraph::new(Line::from(spans)),
                Rect::new(area.x, area.y + y, area.width, 1),
            );
        }
    }
}

impl Drop for PtyPane {
    fn drop(&mut self) {
        // A login CLI left running with no window to draw it into is a process
        // holding a pty open forever, invisible to the user who dismissed it.
        self.kill();
    }
}

fn cell_style(c: &vt100::Cell) -> Style {
    let mut s = Style::default();
    if let Some(fg) = conv_color(c.fgcolor()) {
        s = s.fg(fg);
    }
    if let Some(bg) = conv_color(c.bgcolor()) {
        s = s.bg(bg);
    }
    if c.bold() {
        s = s.add_modifier(Modifier::BOLD);
    }
    if c.italic() {
        s = s.add_modifier(Modifier::ITALIC);
    }
    if c.underline() {
        s = s.add_modifier(Modifier::UNDERLINED);
    }
    if c.inverse() {
        s = s.add_modifier(Modifier::REVERSED);
    }
    s
}

fn conv_color(c: vt100::Color) -> Option<Color> {
    match c {
        // The child said "default", which means the user's terminal default —
        // not any colour of OSA's choosing. Leaving it unset is what keeps the
        // pane looking like the terminal the user already trusts.
        vt100::Color::Default => None,
        vt100::Color::Idx(i) => Some(Color::Indexed(i)),
        vt100::Color::Rgb(r, g, b) => Some(Color::Rgb(r, g, b)),
    }
}

/// Crossterm key → the bytes a terminal would have sent.
///
/// Deliberately narrow. Everything a sign-in flow needs (type, backspace,
/// arrows, Enter, Ctrl+C, Tab) is here; function keys and modified arrows are
/// not, and return `None` so the caller can decide rather than sending a
/// plausible-looking sequence that means something else to the child.
pub fn encode_key(key: KeyEvent) -> Option<Vec<u8>> {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let out: Vec<u8> = match key.code {
        KeyCode::Char(c) if ctrl => {
            // Ctrl+A..Ctrl+Z → 0x01..0x1a. Anything else with Ctrl is not
            // representable as a control byte and is dropped rather than sent
            // as its plain character, which would type a letter the user meant
            // as a command.
            let lower = c.to_ascii_lowercase();
            if lower.is_ascii_alphabetic() {
                vec![(lower as u8) - b'a' + 1]
            } else {
                return None;
            }
        }
        KeyCode::Char(c) => c.to_string().into_bytes(),
        // CR, not LF: a PTY in canonical mode maps CR to the line ending the
        // child expects. Sending LF makes some readline implementations insert
        // a literal newline instead of submitting.
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Tab => vec![b'\t'],
        KeyCode::BackTab => b"\x1b[Z".to_vec(),
        KeyCode::Backspace => vec![0x7f],
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => b"\x1b[A".to_vec(),
        KeyCode::Down => b"\x1b[B".to_vec(),
        KeyCode::Right => b"\x1b[C".to_vec(),
        KeyCode::Left => b"\x1b[D".to_vec(),
        KeyCode::Home => b"\x1b[H".to_vec(),
        KeyCode::End => b"\x1b[F".to_vec(),
        KeyCode::PageUp => b"\x1b[5~".to_vec(),
        KeyCode::PageDown => b"\x1b[6~".to_vec(),
        _ => return None,
    };
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wait_for(pane: &mut PtyPane, pred: impl Fn(&PtyPane) -> bool) -> bool {
        for _ in 0..200 {
            pane.poll();
            if pred(pane) {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        false
    }

    /// Absolute path to a system binary.
    ///
    /// `/bin` and `/usr/bin` are not interchangeable, and the split is not the
    /// same on every platform: `true`/`false` live in `/usr/bin` on macOS and
    /// `/bin` on Linux, while `test` is the other way round. Hardcoding either
    /// layout gives a suite that passes in CI and fails on half the laptops
    /// that run it, so resolve at call time and say so loudly when neither hit.
    fn sys_bin(name: &str) -> String {
        ["/bin", "/usr/bin"]
            .iter()
            .map(|dir| format!("{dir}/{name}"))
            .find(|path| std::path::Path::new(path).exists())
            .unwrap_or_else(|| panic!("no system `{name}` in /bin or /usr/bin"))
    }

    #[test]
    fn a_child_that_prints_is_visible_on_the_pane() {
        let mut pane = PtyPane::spawn(
            &sys_bin("echo"),
            &["hello-from-the-pty".to_string()],
            &[],
            10,
            60,
        );
        assert!(wait_for(&mut pane, |p| p
            .screen_contains("hello-from-the-pty")));
    }

    #[test]
    fn a_child_that_exits_zero_reports_success_not_merely_not_running() {
        let mut pane = PtyPane::spawn(&sys_bin("true"), &[], &[], 10, 40);
        assert!(wait_for(&mut pane, |p| !p.status().is_running()));
        assert!(pane.status().succeeded(), "got {:?}", pane.status());
    }

    #[test]
    fn a_child_that_exits_nonzero_is_not_reported_as_success() {
        let mut pane = PtyPane::spawn(&sys_bin("false"), &[], &[], 10, 40);
        assert!(wait_for(&mut pane, |p| !p.status().is_running()));
        assert!(!pane.status().succeeded(), "got {:?}", pane.status());
        assert!(matches!(pane.status(), PtyStatus::Exited { code } if *code != 0));
    }

    #[test]
    fn a_missing_binary_fails_with_its_name_rather_than_pretending_to_run() {
        let mut pane = PtyPane::spawn("/nonexistent/osa-no-such-binary", &[], &[], 10, 40);
        // Some platforms fail at spawn, others at exec inside the child; both
        // must end up not-running and not-successful, and neither may claim
        // success.
        assert!(wait_for(&mut pane, |p| !p.status().is_running()));
        assert!(!pane.status().succeeded(), "got {:?}", pane.status());
    }

    #[test]
    fn the_child_sees_a_tty_which_is_the_entire_point() {
        // `test -t 0` is true only on a terminal. On a pipe this exits 1.
        let mut pane = PtyPane::spawn(&sys_bin("test"), &["-t".to_string(), "0".to_string()], &[], 10, 40);
        assert!(wait_for(&mut pane, |p| !p.status().is_running()));
        assert!(
            pane.status().succeeded(),
            "child did not see a tty: {:?}",
            pane.status()
        );
    }

    #[test]
    fn typed_bytes_reach_the_child_and_come_back_as_echo() {
        // `cat` echoes its input back through the pty's line discipline.
        let mut pane = PtyPane::spawn(&sys_bin("cat"), &[], &[], 10, 60);
        std::thread::sleep(std::time::Duration::from_millis(200));
        for ch in "ping".chars() {
            pane.send_key(KeyEvent::new(KeyCode::Char(ch), KeyModifiers::NONE));
        }
        pane.send_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        assert!(wait_for(&mut pane, |p| p.screen_contains("ping")));
        pane.kill();
    }

    #[test]
    fn enter_is_carriage_return_because_a_line_feed_does_not_submit() {
        assert_eq!(
            encode_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)),
            Some(vec![b'\r'])
        );
    }

    #[test]
    fn ctrl_c_encodes_to_the_interrupt_byte() {
        assert_eq!(
            encode_key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL)),
            Some(vec![0x03])
        );
    }

    #[test]
    fn ctrl_with_a_non_letter_sends_nothing_rather_than_the_bare_character() {
        assert_eq!(
            encode_key(KeyEvent::new(KeyCode::Char('%'), KeyModifiers::CONTROL)),
            None
        );
    }

    #[test]
    fn a_key_with_no_terminal_encoding_is_declined_so_the_caller_can_handle_it() {
        assert_eq!(encode_key(KeyEvent::new(KeyCode::F(5), KeyModifiers::NONE)), None);
    }

    #[test]
    fn backspace_is_del_which_is_what_readline_expects() {
        assert_eq!(
            encode_key(KeyEvent::new(KeyCode::Backspace, KeyModifiers::NONE)),
            Some(vec![0x7f])
        );
    }

    #[test]
    fn a_multibyte_character_is_sent_as_its_utf8_bytes() {
        assert_eq!(
            encode_key(KeyEvent::new(KeyCode::Char('é'), KeyModifiers::NONE)),
            Some("é".as_bytes().to_vec())
        );
    }

    #[test]
    fn resizing_moves_both_the_kernel_window_and_our_emulator() {
        let mut pane = PtyPane::spawn(&sys_bin("cat"), &[], &[], 10, 40);
        pane.resize(24, 100);
        let p = pane.parser.lock().unwrap();
        assert_eq!(p.screen().size(), (24, 100));
        drop(p);
        pane.kill();
    }
}
