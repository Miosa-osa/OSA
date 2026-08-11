use crossterm::event::EventStream;
use futures::{Stream, StreamExt};
use tokio::sync::mpsc;
use tracing::{debug, error};

use super::Event;

// ── ESC handling: what was measured, so it is not re-litigated ───────────────
//
// There is a persistent folk belief — it was written into this harness's own
// `_escape_out` helper — that crossterm holds a lone `ESC` byte in its parse
// buffer waiting to see whether it is the start of `ESC [ A`, and that OSA
// therefore needs an "ESC disambiguation timeout" here. **It does not.**
// Measured against crossterm 0.28.1, both standalone on a kernel PTY and
// against the real `osagent` binary through `test/pty`:
//
//   * a lone `ESC` with nothing behind it is delivered as `KeyCode::Esc`
//     immediately — 100% of trials, and the dialog it closes is gone ~55ms
//     later (that 55ms is OSA's own draw cadence, not input latency);
//   * an `ESC [ A` arriving as ONE read parses as one `Up`;
//   * an `ESC [ A` arriving SPLIT (`ESC`, then `[A`) is already shredded into
//     `Esc` + `Char('[')` + `Char('A')` — at any gap, down to 0.2ms.
//
// The mechanism is in `crossterm/src/event/source/unix/tty.rs`: the tty source
// calls `Parser::advance(&buf[..n], n == TTY_BUFFER_SIZE)`, so the last byte of
// any read that did not fill 1024 bytes is parsed with `input_available =
// false`, and `parse_event` answers a one-byte `[0x1B]` buffer with `Esc` on
// the spot (`sys/unix/parse.rs`). crossterm never waits.
//
// So an ESC timeout here would be pure regression: it would add its own delay
// to every Esc press, and it could not repair the split-sequence case anyway —
// by the time an event reaches this function crossterm has already decided, and
// re-assembling `Esc` + `Char('[')` + `Char('A')` back into `Up` means owning a
// copy of crossterm's parse table. Do not add one; the tests below pin this.
//
// The real defect in this layer is the opposite one, and it is NOT fixable
// here: a PARTIAL escape sequence (`ESC [` with no terminator, e.g. Alt+`[`)
// leaves crossterm's parse buffer wedged, and it silently eats the NEXT
// keystroke. Verified against the real binary: typing `ESC [` then `WORLD`
// puts `ORLD` in the composer. `parse_csi` returns `Ok(None)` for a 2-byte
// buffer regardless of `input_available`, so the buffer is kept forever, and
// crossterm 0.29 does not change this. Fixing it requires either patching the
// crate or reading and parsing the tty here instead of using `EventStream`.

/// How many *consecutive* read failures the terminal reader absorbs before it
/// gives up and lets the task end.
///
/// A single `Err` from the event stream is not a reason to stop reading input.
/// Real terminals hand us transient garbage all the time: a stray non-UTF8
/// paste, a device-status reply crossterm does not model, a syscall interrupted
/// by a signal (EINTR) during a resize. Treating any one of those as fatal ends
/// the reader task permanently — and because nothing respawns it outside of
/// alt-screen transitions, the TUI keeps ticking and redrawing while accepting
/// *zero* keystrokes for the rest of the session.
///
/// The counter resets on every successful read, so this budget only expires on
/// a sustained run of failures — i.e. a genuinely dead input source, where
/// exiting is correct and spinning forever is not.
pub const MAX_CONSECUTIVE_TERMINAL_ERRORS: usize = 50;

/// Drive an event stream into the unified channel, tolerating transient errors.
///
/// Split out from [`spawn_terminal_reader`] so the error-tolerance policy can be
/// exercised against a scripted stream in tests; the production caller passes
/// crossterm's [`EventStream`].
///
/// Returns when the receiver is dropped, the stream ends, or
/// [`MAX_CONSECUTIVE_TERMINAL_ERRORS`] failures arrive back to back.
pub async fn pump_terminal_events<S, E>(mut reader: S, tx: mpsc::UnboundedSender<Event>)
where
    S: Stream<Item = Result<crossterm::event::Event, E>> + Unpin,
    E: std::fmt::Display,
{
    let mut consecutive_errors = 0usize;

    loop {
        match reader.next().await {
            Some(Ok(event)) => {
                // Any successful read proves the input source is alive again.
                consecutive_errors = 0;
                if tx.send(Event::Terminal(event)).is_err() {
                    break; // receiver dropped
                }
            }
            Some(Err(e)) => {
                consecutive_errors += 1;
                if consecutive_errors >= MAX_CONSECUTIVE_TERMINAL_ERRORS {
                    error!(
                        "Terminal event reader giving up after {} consecutive errors; \
                         last error: {}",
                        consecutive_errors, e
                    );
                    break;
                }
                debug!(
                    "Terminal event error ({}/{}), continuing to read: {}",
                    consecutive_errors, MAX_CONSECUTIVE_TERMINAL_ERRORS, e
                );
            }
            None => break,
        }
    }
}

/// Spawn terminal event reader task.
/// Reads from crossterm's async EventStream and forwards into the unified mpsc channel.
pub fn spawn_terminal_reader(tx: mpsc::UnboundedSender<Event>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        pump_terminal_events(EventStream::new(), tx).await;
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEvent};

    fn key(c: char) -> CrosstermEvent {
        CrosstermEvent::Key(KeyEvent::from(KeyCode::Char(c)))
    }

    fn err() -> std::io::Error {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "stream of nonsense bytes")
    }

    fn esc() -> CrosstermEvent {
        CrosstermEvent::Key(KeyEvent::from(KeyCode::Esc))
    }

    /// Drain the channel into the characters that arrived as key events.
    fn drained(rx: &mut mpsc::UnboundedReceiver<Event>) -> String {
        let mut out = String::new();
        while let Ok(ev) = rx.try_recv() {
            if let Event::Terminal(CrosstermEvent::Key(k)) = ev {
                if let KeyCode::Char(c) = k.code {
                    out.push(c);
                }
            }
        }
        out
    }

    /// THE defect: one parse error used to `break` the reader loop, and nothing
    /// respawns the task, so every keystroke after the error was dropped for the
    /// rest of the session. The reader must survive the error and keep
    /// delivering.
    #[tokio::test]
    async fn a_single_read_error_does_not_kill_the_reader() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let stream = futures::stream::iter(vec![Ok(key('a')), Err(err()), Ok(key('b'))]);

        pump_terminal_events(stream, tx).await;

        assert_eq!(
            drained(&mut rx),
            "ab",
            "keys before AND after a transient read error must both arrive"
        );
    }

    /// The budget is for *consecutive* failures: a success in between must clear
    /// it, so a terminal that hiccups periodically never exhausts it.
    #[tokio::test]
    async fn a_success_resets_the_consecutive_error_budget() {
        let (tx, mut rx) = mpsc::unbounded_channel();

        // Two runs of (MAX - 1) errors, separated by a good read. Without the
        // reset this totals well past the budget and the tail is lost.
        let mut script: Vec<Result<CrosstermEvent, std::io::Error>> = Vec::new();
        for _ in 0..MAX_CONSECUTIVE_TERMINAL_ERRORS - 1 {
            script.push(Err(err()));
        }
        script.push(Ok(key('x')));
        for _ in 0..MAX_CONSECUTIVE_TERMINAL_ERRORS - 1 {
            script.push(Err(err()));
        }
        script.push(Ok(key('y')));

        pump_terminal_events(futures::stream::iter(script), tx).await;

        assert_eq!(
            drained(&mut rx),
            "xy",
            "a successful read must clear the error budget"
        );
    }

    /// A genuinely dead input source must still terminate the task rather than
    /// spin forever: once the budget is exhausted nothing further is delivered.
    #[tokio::test]
    async fn a_sustained_error_run_still_gives_up() {
        let (tx, mut rx) = mpsc::unbounded_channel();

        let mut script: Vec<Result<CrosstermEvent, std::io::Error>> = Vec::new();
        for _ in 0..MAX_CONSECUTIVE_TERMINAL_ERRORS {
            script.push(Err(err()));
        }
        // Never reached — the reader has already given up.
        script.push(Ok(key('z')));

        pump_terminal_events(futures::stream::iter(script), tx).await;

        assert_eq!(
            drained(&mut rx),
            "",
            "after an unbroken run of {MAX_CONSECUTIVE_TERMINAL_ERRORS} errors the reader stops"
        );
    }

    /// A lone `Esc` with NOTHING behind it must be forwarded immediately.
    ///
    /// The stream yields one `Esc` and then pends forever, which is exactly the
    /// situation the folklore says breaks: a user pressing Esc in a quiet TUI,
    /// with no subsequent keystroke to "wake" anything. If the reader ever
    /// grows an ESC-disambiguation hold — a timer that sits on the `Esc`
    /// waiting to see whether an arrow key follows — this test is what catches
    /// it, because nothing will ever follow and the wait cannot be satisfied.
    ///
    /// See the module header for why that hold would be wrong: crossterm has
    /// already made the bare-`ESC`-vs-`ESC [ A` decision before the event
    /// reaches this function, so a hold here buys nothing and costs latency on
    /// every Esc press.
    ///
    /// The clock is PAUSED, and that is the whole mechanism of the assertion
    /// rather than a speed-up. Under `start_paused` tokio only advances virtual
    /// time when the runtime has no runnable task, so a reader that forwards
    /// the Esc straight through delivers it at virtual t=0, while a reader that
    /// parks it behind a timer of ANY duration — 25ms, 50ms, an hour — forces
    /// an auto-advance to that instant and moves the clock. Asserting "the
    /// clock did not move" therefore catches every timer-shaped hold with no
    /// wall-clock threshold to tune and nothing to go flaky under load. (A
    /// plain `timeout(250ms, …)` bound does NOT: it lets a conventional 25-50ms
    /// ESC timeout through, which was verified by planting one.)
    ///
    /// The outer timeout is only a hang guard — under the paused clock it
    /// resolves in virtual time, so it costs no real seconds.
    #[tokio::test(start_paused = true)]
    async fn a_lone_esc_with_no_follow_on_is_delivered_not_held() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let stream = Box::pin(
            futures::stream::iter(vec![Ok::<_, std::io::Error>(esc())])
                .chain(futures::stream::pending()),
        );
        let started = tokio::time::Instant::now();
        let pump = tokio::spawn(pump_terminal_events(stream, tx));

        let delivered = tokio::time::timeout(std::time::Duration::from_secs(60), rx.recv())
            .await
            .expect(
                "a lone Esc with no follow-on input was never delivered — the reader is \
                 holding it (see the module header: crossterm does not, and neither may we)",
            );
        let held_for = started.elapsed();

        assert!(
            matches!(
                delivered,
                Some(Event::Terminal(CrosstermEvent::Key(KeyEvent {
                    code: KeyCode::Esc,
                    ..
                })))
            ),
            "expected the Esc key event, got {delivered:?}"
        );
        assert_eq!(
            held_for,
            std::time::Duration::ZERO,
            "the reader parked the Esc behind a timer for {held_for:?}. There is no \
             disambiguation left to do at this layer — crossterm already decided — so \
             every one of those milliseconds is added latency on a key the user pressed \
             to get OUT of something. See the module header."
        );

        pump.abort();
    }

    /// An Esc immediately behind other input is still exactly one Esc, in
    /// order. Guards the same hold from a different angle: a reader that
    /// buffered the Esc "just in case" would either reorder it behind the next
    /// key or emit it twice.
    #[tokio::test]
    async fn an_esc_between_keys_arrives_once_and_in_order() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let script = vec![
            Ok::<_, std::io::Error>(key('a')),
            Ok(esc()),
            Ok(key('b')),
        ];

        pump_terminal_events(futures::stream::iter(script), tx).await;

        let mut codes = Vec::new();
        while let Ok(Event::Terminal(CrosstermEvent::Key(k))) = rx.try_recv() {
            codes.push(k.code);
        }
        assert_eq!(
            codes,
            vec![KeyCode::Char('a'), KeyCode::Esc, KeyCode::Char('b')],
            "the Esc must pass through in order, exactly once"
        );
    }

    /// Dropping the receiver ends the reader (the original, correct exit path).
    #[tokio::test]
    async fn a_dropped_receiver_ends_the_reader() {
        let (tx, rx) = mpsc::unbounded_channel();
        drop(rx);

        let script: Vec<Result<CrosstermEvent, std::io::Error>> =
            vec![Ok(key('a')), Ok(key('b'))];

        // Must return rather than hang.
        pump_terminal_events(futures::stream::iter(script), tx).await;
    }
}
