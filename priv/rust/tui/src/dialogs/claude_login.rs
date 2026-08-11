//! Install and sign in to Claude Code **without leaving OSA**.
//!
//! ## The rule this exists to satisfy
//!
//! Everything happens inside the harness. Before this screen, connecting a
//! Claude Pro/Max plan meant reading "Claude Code is not installed" or "run
//! `claude auth login` then re-run OSA setup", quitting, doing it, and coming
//! back — three context switches for a provider whose whole appeal is that the
//! user already pays for it.
//!
//! ## What it does NOT do
//!
//! It does not implement an Anthropic OAuth flow. That path was deliberately
//! removed (see `Auth.LegacyAnthropicOAuth`), and re-adding it puts the user's
//! own account at risk. Everything here spawns **Anthropic's own binary** on a
//! pty and shows the user what it prints. OSA is the window, never the client:
//! the credential is minted by Claude Code, stored by Claude Code, and OSA
//! afterwards knows only that a sign-in succeeded.
//!
//! ## Why the backend decides what to run
//!
//! The argv comes from `Auth.Providers.ClaudeCli.cli_state/0`, which reads the
//! installed binary's own `--help`. The CLI has shipped `claude login`,
//! `claude auth login` and `claude setup-token` at different points; a TUI that
//! picked one by guessing would hand a user `unknown command` from a binary
//! that was perfectly able to sign them in. This file renders a decision, it
//! does not make one.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Paragraph, Wrap},
};

use super::pty_pane::{PtyPane, PtyStatus};
use crate::client::types::ClaudeCliState;

/// Detach key for a running child: Ctrl+] , the telnet escape.
///
/// It has to be something the child will never want, and every obvious
/// candidate is taken — Esc, arrows and Enter all belong to Claude Code's own
/// menus, and swallowing Esc here is what would make its "go back" unreachable.
const DETACH_HINT: &str = "Ctrl+]";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClaudeLoginAction {
    /// Re-read `/auth/cli/claude`. Emitted after a child exits, because the
    /// child is the only thing that knows whether it worked and OSA must ask
    /// the binary rather than infer from an exit code alone.
    Refresh,
    /// Signed in, verified, and the account is on screen. The caller may now
    /// select the provider.
    Connected,
    /// Dismissed with nothing changed.
    Cancel,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phase {
    /// Waiting for the first `/auth/cli/claude`.
    Loading,
    /// No binary. Offers to run the install command here.
    NotInstalled,
    /// Installed, signed out. Offers to run the detected login command here.
    NeedsLogin,
    /// A child is on the pty. `install` distinguishes the two only for the
    /// wording and for what happens when it exits cleanly.
    Running { install: bool },
    /// A child exited; we have asked the backend what actually changed. This
    /// is a real state and not a flicker: an exit code of 0 from a login CLI
    /// is not evidence of a credential, and reporting success on it is how a
    /// status screen becomes confidently wrong.
    Verifying,
    /// Signed in. Shows email, org and plan.
    Connected,
    /// Something is wrong that running a command will not fix — no login
    /// subcommand could be identified, or the CLI is below the floor.
    Blocked { reason: String },
}

pub struct ClaudeLogin {
    state: Option<ClaudeCliState>,
    phase: Phase,
    pane: Option<PtyPane>,
    /// Cleared on drop; a background repaint ticker watches it so a dismissed
    /// dialog cannot leave a task waking the event loop forever.
    pub alive: Arc<AtomicBool>,
    /// Set when a child has exited and its outcome has not yet been folded in.
    /// Kept so the pane's final screen — which usually holds the CLI's own
    /// error text — stays visible instead of being replaced by a spinner.
    last_exit: Option<PtyStatus>,
    /// Measured on draw so `resize` can match the child's window to the pane.
    pane_size: std::cell::Cell<(u16, u16)>,
}

impl Default for ClaudeLogin {
    fn default() -> Self {
        Self::new()
    }
}

impl ClaudeLogin {
    pub fn new() -> Self {
        Self {
            state: None,
            phase: Phase::Loading,
            pane: None,
            alive: Arc::new(AtomicBool::new(true)),
            last_exit: None,
            pane_size: std::cell::Cell::new((20, 80)),
        }
    }

    pub fn phase(&self) -> &Phase {
        &self.phase
    }

    pub fn state(&self) -> Option<&ClaudeCliState> {
        self.state.as_ref()
    }

    /// True while a child owns the keyboard.
    pub fn is_child_running(&self) -> bool {
        matches!(self.phase, Phase::Running { .. })
            && self.pane.as_ref().is_some_and(|p| p.status().is_running())
    }

    // ── Backend readings ─────────────────────────────────────────────────

    /// Fold in a reading of `/auth/cli/claude`.
    ///
    /// Never returns `Connected` on its own. A sign-in that completes and
    /// immediately closes the screen is how the owner ended up unsure which
    /// account OSA had connected: the one moment the answer is guaranteed to
    /// be fresh is the moment it flashed past. The success screen names the
    /// email, org and plan and waits for Enter — one keystroke, in exchange
    /// for the user actually knowing what they just connected.
    pub fn apply_state(&mut self, state: ClaudeCliState) -> Option<ClaudeLoginAction> {
        // A reading that lands while a child is mid-run is stale by
        // construction: the child is the thing changing the answer. Store it,
        // but do not let it move the screen out from under the pty.
        let running = self.is_child_running();
        self.state = Some(state);
        if running {
            return None;
        }
        self.phase = self.derive_phase();
        None
    }

    /// The fetch itself failed. Distinguished from "the CLI is missing":
    /// nothing was learned, so nothing may be asserted about the binary.
    pub fn apply_fetch_error(&mut self, err: String) {
        self.phase = Phase::Blocked {
            reason: format!("Could not ask OSA about Claude Code: {}", err),
        };
    }

    fn derive_phase(&self) -> Phase {
        let s = match self.state.as_ref() {
            Some(s) => s,
            None => return Phase::Loading,
        };
        if !s.installed {
            return Phase::NotInstalled;
        }
        if s.version_ok == Some(false) {
            return Phase::Blocked {
                reason: format!(
                    "Claude Code {} is older than the {} OSA needs. Run  claude update  and reopen this screen.",
                    s.version.as_deref().unwrap_or("(unknown)"),
                    s.min_version.as_deref().unwrap_or("minimum")
                ),
            };
        }
        if s.signed_in {
            return Phase::Connected;
        }
        match s.login_argv.as_ref() {
            Some(argv) if !argv.is_empty() => Phase::NeedsLogin,
            _ => Phase::Blocked {
                reason: format!(
                    "This Claude Code build did not name a login subcommand OSA recognises{}. \
                     Sign in with the CLI directly, then reopen this screen — OSA will pick it up.",
                    s.login_error
                        .as_deref()
                        .map(|e| format!(" ({})", e))
                        .unwrap_or_default()
                ),
            },
        }
    }

    // ── Ticking ──────────────────────────────────────────────────────────

    /// Poll the child. Call on every tick while this dialog is open.
    pub fn tick(&mut self) -> Option<ClaudeLoginAction> {
        let installing = match self.phase {
            Phase::Running { install } => install,
            _ => return None,
        };
        let pane = self.pane.as_mut()?;
        let status = pane.poll().clone();
        if status.is_running() {
            return None;
        }

        self.last_exit = Some(status.clone());
        let _ = installing;
        // Whatever it was — install or login — the honest next step is the
        // same: ask the backend what the binary now says. An install that
        // exits 0 may still not be on PATH; a login that exits 0 may have been
        // cancelled at the browser. Neither exit code is evidence.
        self.phase = Phase::Verifying;
        Some(ClaudeLoginAction::Refresh)
    }

    // ── Keys ─────────────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<ClaudeLoginAction> {
        // A running child owns the keyboard, with exactly one exception.
        if self.is_child_running() {
            if key.code == KeyCode::Char(']') && key.modifiers.contains(KeyModifiers::CONTROL) {
                self.abort_child();
                return None;
            }
            if let Some(pane) = self.pane.as_mut() {
                pane.send_key(key);
            }
            return None;
        }

        match (&self.phase, key.code) {
            (_, KeyCode::Esc) => Some(ClaudeLoginAction::Cancel),
            (Phase::Connected, KeyCode::Enter) => Some(ClaudeLoginAction::Connected),
            (Phase::NotInstalled, KeyCode::Enter) => {
                self.start_install();
                None
            }
            (Phase::NeedsLogin, KeyCode::Enter) => {
                self.start_login();
                None
            }
            // A finished child's screen is still up; any of these dismisses it
            // and re-asks the backend rather than leaving the user staring at
            // a dead pane with no way forward.
            (Phase::Verifying, KeyCode::Enter | KeyCode::Char('r')) => {
                Some(ClaudeLoginAction::Refresh)
            }
            (Phase::Blocked { .. }, KeyCode::Char('r')) => Some(ClaudeLoginAction::Refresh),
            _ => None,
        }
    }

    /// Send pasted text to the running child. A no-op when nothing is running,
    /// so a stray paste on the "press Enter to sign in" screen does nothing
    /// rather than going somewhere surprising.
    pub fn paste(&mut self, text: &str) {
        if !self.is_child_running() {
            return;
        }
        if let Some(pane) = self.pane.as_mut() {
            // CRLF normalised to CR: a pty's line discipline treats CR as
            // submit, and a pasted CRLF would submit twice.
            let normalised = text.replace("\r\n", "\r").replace('\n', "\r");
            pane.write(normalised.as_bytes());
        }
    }

    fn abort_child(&mut self) {
        if let Some(pane) = self.pane.as_mut() {
            pane.kill();
        }
        self.phase = Phase::Verifying;
    }

    // ── Spawning ─────────────────────────────────────────────────────────

    /// The environment a spawned child gets.
    ///
    /// Mirrors `Auth.Providers.ClaudeCli.probe_env/0` and for the same reason:
    /// an `ANTHROPIC_API_KEY` inherited from OSA's own environment makes the
    /// CLI answer about the key instead of the subscription, and would leave
    /// the user billed per-token through a provider they chose precisely to
    /// avoid that.
    fn child_env() -> Vec<(String, Option<String>)> {
        vec![
            ("ANTHROPIC_API_KEY".into(), None),
            ("ANTHROPIC_AUTH_TOKEN".into(), None),
            ("ANTHROPIC_BASE_URL".into(), None),
        ]
    }

    fn start_install(&mut self) {
        let argv = self
            .state
            .as_ref()
            .map(|s| s.install_argv.clone())
            .unwrap_or_default();
        if argv.is_empty() {
            return;
        }
        let (rows, cols) = self.pane_size.get();
        self.last_exit = None;
        self.pane = Some(PtyPane::spawn(
            &argv[0],
            &argv[1..],
            &Self::child_env(),
            rows,
            cols,
        ));
        self.phase = Phase::Running { install: true };
    }

    fn start_login(&mut self) {
        let (program, argv) = match self.state.as_ref() {
            Some(s) => (
                s.login_program.clone().unwrap_or_else(|| "claude".into()),
                s.login_argv.clone().unwrap_or_default(),
            ),
            None => return,
        };
        if argv.is_empty() {
            return;
        }
        let (rows, cols) = self.pane_size.get();
        self.last_exit = None;
        self.pane = Some(PtyPane::spawn(
            &program,
            &argv,
            &Self::child_env(),
            rows,
            cols,
        ));
        self.phase = Phase::Running { install: false };
    }

    /// Match the child's window to the pane it was last drawn into.
    /// Called from the tick path, because `draw` cannot mutate.
    pub fn sync_pane_size(&mut self) {
        let (rows, cols) = self.pane_size.get();
        if let Some(pane) = self.pane.as_mut() {
            pane.resize(rows, cols);
        }
    }

    /// The child's screen as text. Test support and failure evidence.
    pub fn child_screen(&self) -> String {
        self.pane.as_ref().map(|p| p.screen_text()).unwrap_or_default()
    }

    // ── Drawing ──────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect, theme: &crate::style::Theme) {
        let title = match &self.phase {
            Phase::Running { install: true } => " Installing Claude Code ".to_string(),
            Phase::Running { install: false } => " Claude Code sign-in ".to_string(),
            _ => " Connect Claude ".to_string(),
        };

        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.border))
            .title(Span::styled(title, theme.dialog_title()))
            .style(Style::default().bg(theme.colors.dialog_bg));
        let inner = block.inner(area);
        frame.render_widget(ratatui::widgets::Clear, area);
        frame.render_widget(block, area);
        if inner.width == 0 || inner.height == 0 {
            return;
        }

        match &self.phase {
            Phase::Running { install } => self.draw_running(frame, inner, theme, *install),
            Phase::Verifying => self.draw_verifying(frame, inner, theme),
            Phase::Loading => {
                frame.render_widget(
                    Paragraph::new("  Asking OSA about Claude Code…")
                        .style(Style::default().fg(theme.colors.muted)),
                    Rect::new(inner.x, inner.y, inner.width, 1),
                );
            }
            Phase::NotInstalled => self.draw_not_installed(frame, inner, theme),
            Phase::NeedsLogin => self.draw_needs_login(frame, inner, theme),
            Phase::Connected => self.draw_connected(frame, inner, theme),
            Phase::Blocked { reason } => {
                let body = vec![
                    Line::from(Span::styled(
                        "  Claude Code cannot be driven from here",
                        Style::default().fg(theme.colors.warning),
                    )),
                    Line::from(""),
                    Line::from(Span::styled(
                        format!("  {}", reason),
                        Style::default().fg(theme.colors.muted),
                    )),
                ];
                frame.render_widget(
                    Paragraph::new(body).wrap(Wrap { trim: false }),
                    Rect::new(inner.x, inner.y, inner.width, inner.height.saturating_sub(1)),
                );
                self.footer(frame, inner, theme, &[("r", "re-check"), ("Esc", "back")]);
            }
        }
    }

    fn draw_running(
        &self,
        frame: &mut Frame,
        inner: Rect,
        theme: &crate::style::Theme,
        install: bool,
    ) {
        let cmd = self
            .pane
            .as_ref()
            .map(|p| p.command_line.clone())
            .unwrap_or_default();
        frame.render_widget(
            Paragraph::new(Span::styled(
                format!("  $ {}", cmd),
                Style::default().fg(theme.colors.dim),
            )),
            Rect::new(inner.x, inner.y, inner.width, 1),
        );

        let pane_area = Rect::new(
            inner.x + 1,
            inner.y + 2,
            inner.width.saturating_sub(2),
            inner.height.saturating_sub(4),
        );
        self.pane_size.set((pane_area.height.max(1), pane_area.width.max(1)));
        if let Some(pane) = self.pane.as_ref() {
            pane.draw(frame, pane_area);
        }

        let hint = if install {
            // Named from what is actually running, not hardcoded to "npm":
            // the backend chooses the install command, and a hint that names a
            // program the user is not looking at is worse than none.
            let prog = cmd
                .split_whitespace()
                .next()
                .and_then(|p| p.rsplit('/').next())
                .unwrap_or("the installer")
                .to_string();
            format!("keys go to {} · {} stop", prog, DETACH_HINT)
        } else {
            format!(
                "keys go to Claude Code · {} stop · your credential stays in Claude Code",
                DETACH_HINT
            )
        };
        frame.render_widget(
            Paragraph::new(Span::styled(
                format!("  {}", hint),
                Style::default().fg(theme.colors.dim),
            )),
            Rect::new(
                inner.x,
                inner.y + inner.height.saturating_sub(1),
                inner.width,
                1,
            ),
        );
    }

    fn draw_verifying(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let mut lines = vec![];
        match &self.last_exit {
            Some(PtyStatus::Exited { code: 0 }) => lines.push(Line::from(Span::styled(
                "  Finished. Checking with Claude Code…",
                Style::default().fg(theme.colors.muted),
            ))),
            Some(PtyStatus::Exited { code }) => lines.push(Line::from(Span::styled(
                format!("  That command exited {} — its output is above.", code),
                Style::default().fg(theme.colors.warning),
            ))),
            Some(PtyStatus::Failed { reason }) => lines.push(Line::from(Span::styled(
                format!("  {}", reason),
                Style::default().fg(theme.colors.error),
            ))),
            _ => lines.push(Line::from(Span::styled(
                "  Stopped. Checking with Claude Code…",
                Style::default().fg(theme.colors.muted),
            ))),
        }
        frame.render_widget(
            Paragraph::new(lines).wrap(Wrap { trim: false }),
            Rect::new(inner.x, inner.y, inner.width, 2),
        );

        // The child's last screen is the evidence for whatever it just said,
        // so it stays up rather than being cleared behind a status line.
        let pane_area = Rect::new(
            inner.x + 1,
            inner.y + 3,
            inner.width.saturating_sub(2),
            inner.height.saturating_sub(5),
        );
        if let Some(pane) = self.pane.as_ref() {
            pane.draw(frame, pane_area);
        }
        self.footer(frame, inner, theme, &[("Enter", "re-check"), ("Esc", "back")]);
    }

    fn draw_not_installed(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let cmd = self
            .state
            .as_ref()
            .map(|s| s.install_argv.join(" "))
            .unwrap_or_default();

        let body = vec![
            Line::from(Span::styled(
                "  Claude Code is Anthropic's own command-line client.",
                Style::default().fg(theme.colors.muted),
            )),
            Line::from(Span::styled(
                "  OSA runs it for inference, so your Claude Pro/Max plan is billed",
                Style::default().fg(theme.colors.muted),
            )),
            Line::from(Span::styled(
                "  instead of per-token API credit.",
                Style::default().fg(theme.colors.muted),
            )),
            Line::from(""),
            Line::from(Span::styled(
                "  It isn't installed on this machine. One command fixes that:",
                Style::default().fg(theme.colors.secondary),
            )),
            Line::from(""),
            Line::from(Span::styled(
                format!("      {}", cmd),
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            )),
            Line::from(""),
            Line::from(Span::styled(
                "  Press Enter and OSA will run it here — you'll see its output as",
                Style::default().fg(theme.colors.muted),
            )),
            Line::from(Span::styled(
                "  it goes, and the sign-in follows in the same place.",
                Style::default().fg(theme.colors.muted),
            )),
        ];
        frame.render_widget(
            Paragraph::new(body),
            Rect::new(inner.x, inner.y, inner.width, inner.height.saturating_sub(1)),
        );
        self.footer(
            frame,
            inner,
            theme,
            &[("Enter", "install it here"), ("Esc", "back")],
        );
    }

    fn draw_needs_login(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let s = self.state.as_ref();
        let cmd = s
            .and_then(|s| s.login_display.clone())
            .unwrap_or_else(|| "claude auth login".into());
        let ver = s
            .and_then(|s| s.version.clone())
            .map(|v| format!(" {}", v))
            .unwrap_or_default();

        let body = vec![
            Line::from(Span::styled(
                format!("  Claude Code{} is installed, but signed out.", ver),
                Style::default().fg(theme.colors.muted),
            )),
            Line::from(""),
            Line::from(Span::styled(
                "  OSA will run its own sign-in here:",
                Style::default().fg(theme.colors.secondary),
            )),
            Line::from(""),
            Line::from(Span::styled(
                format!("      {}", cmd),
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            )),
            Line::from(""),
            Line::from(Span::styled(
                "  Its prompts appear below and your keys go straight to it. The",
                Style::default().fg(theme.colors.muted),
            )),
            Line::from(Span::styled(
                "  browser step is Anthropic's own — OSA never offers a Claude login",
                Style::default().fg(theme.colors.muted),
            )),
            Line::from(Span::styled(
                "  of its own, and never sees the credential that comes back.",
                Style::default().fg(theme.colors.muted),
            )),
        ];
        frame.render_widget(
            Paragraph::new(body),
            Rect::new(inner.x, inner.y, inner.width, inner.height.saturating_sub(1)),
        );
        self.footer(
            frame,
            inner,
            theme,
            &[("Enter", "sign in here"), ("Esc", "back")],
        );
    }

    fn draw_connected(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let s = self.state.as_ref();
        let mut body = vec![
            Line::from(Span::styled(
                "  ✓ Connected through Claude Code",
                Style::default().fg(theme.colors.success),
            )),
            Line::from(""),
        ];
        for line in account_lines(s) {
            body.push(Line::from(vec![
                Span::styled(
                    format!("  {:<9}", line.0),
                    Style::default().fg(theme.colors.dim),
                ),
                Span::styled(line.1, Style::default().fg(theme.colors.muted)),
            ]));
        }
        body.push(Line::from(""));
        body.push(Line::from(Span::styled(
            "  Your credential stays in Claude Code; OSA never sees or stores it.",
            Style::default().fg(theme.colors.dim),
        )));
        frame.render_widget(
            Paragraph::new(body),
            Rect::new(inner.x, inner.y, inner.width, inner.height.saturating_sub(1)),
        );
        self.footer(frame, inner, theme, &[("Enter", "use it"), ("Esc", "back")]);
    }

    fn footer(
        &self,
        frame: &mut Frame,
        inner: Rect,
        theme: &crate::style::Theme,
        keys: &[(&str, &str)],
    ) {
        let mut spans = vec![Span::raw("  ")];
        for (i, (k, label)) in keys.iter().enumerate() {
            if i > 0 {
                spans.push(Span::styled(" · ", Style::default().fg(theme.colors.dim)));
            }
            spans.push(Span::styled(
                *k,
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ));
            spans.push(Span::styled(
                format!(" {}", label),
                Style::default().fg(theme.colors.dim),
            ));
        }
        frame.render_widget(
            Paragraph::new(Line::from(spans)),
            Rect::new(
                inner.x,
                inner.y + inner.height.saturating_sub(1),
                inner.width,
                1,
            ),
        );
    }
}

impl Drop for ClaudeLogin {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::Relaxed);
    }
}

/// The account label rows: email, org and plan.
///
/// All three, always, and never as a number-shaped placeholder. The marker has
/// carried org and plan since it was first written and only the email was ever
/// shown, which left a user with a personal and a work Claude account unable to
/// tell which one OSA had connected. A field the CLI did not report renders as
/// "not reported", because "—" beside "Plan" reads as "no plan".
pub fn account_lines(s: Option<&ClaudeCliState>) -> Vec<(&'static str, String)> {
    let unknown = || "not reported".to_string();
    vec![
        (
            "Account",
            s.and_then(|s| s.account.clone())
                .filter(|v| !v.is_empty())
                .unwrap_or_else(unknown),
        ),
        (
            "Org",
            s.and_then(|s| s.org.clone())
                .filter(|v| !v.is_empty())
                .unwrap_or_else(|| "personal".to_string()),
        ),
        (
            "Plan",
            s.and_then(|s| s.plan.clone())
                .filter(|v| !v.is_empty())
                .unwrap_or_else(unknown),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(installed: bool, signed_in: bool) -> ClaudeCliState {
        ClaudeCliState {
            installed,
            path: installed.then(|| "/usr/bin/claude".to_string()),
            version: installed.then(|| "2.1.226".to_string()),
            version_ok: installed.then_some(true),
            min_version: Some("2.0.0".into()),
            signed_in,
            account: signed_in.then(|| "luna@example.com".to_string()),
            org: signed_in.then(|| "Acme Inc".to_string()),
            plan: signed_in.then(|| "max".to_string()),
            login_program: installed.then(|| "/usr/bin/claude".to_string()),
            login_argv: installed.then(|| vec!["auth".to_string(), "login".to_string()]),
            login_display: installed.then(|| "claude auth login".to_string()),
            login_error: None,
            install_argv: vec![
                "npm".into(),
                "install".into(),
                "-g".into(),
                "@anthropic-ai/claude-code".into(),
            ],
            install_url: Some("https://claude.com/product/claude-code".into()),
        }
    }

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    #[test]
    fn a_missing_binary_offers_to_install_rather_than_dead_ending() {
        let mut d = ClaudeLogin::new();
        assert_eq!(d.apply_state(state(false, false)), None);
        assert_eq!(*d.phase(), Phase::NotInstalled);
    }

    #[test]
    fn installing_runs_the_command_here_instead_of_telling_the_user_to_go_away() {
        let mut d = ClaudeLogin::new();
        d.apply_state(state(false, false));
        // No action bubbles up: the work happens inside this dialog.
        assert_eq!(d.handle_key(key(KeyCode::Enter)), None);
        assert!(matches!(d.phase(), Phase::Running { install: true }));
    }

    #[test]
    fn an_installed_signed_out_cli_offers_the_detected_subcommand() {
        let mut d = ClaudeLogin::new();
        d.apply_state(state(true, false));
        assert_eq!(*d.phase(), Phase::NeedsLogin);
        assert_eq!(
            d.state().unwrap().login_display.as_deref(),
            Some("claude auth login")
        );
    }

    #[test]
    fn a_cli_that_names_no_login_subcommand_is_blocked_not_guessed_at() {
        let mut d = ClaudeLogin::new();
        let mut s = state(true, false);
        s.login_argv = None;
        s.login_display = None;
        s.login_error = Some("{:no_login_subcommand, \"Commands: mcp doctor\"}".into());
        d.apply_state(s);
        match d.phase() {
            Phase::Blocked { reason } => {
                assert!(reason.contains("no_login_subcommand"), "got {}", reason)
            }
            other => panic!("expected Blocked, got {:?}", other),
        }
    }

    #[test]
    fn a_cli_below_the_floor_says_which_version_and_what_to_run() {
        let mut d = ClaudeLogin::new();
        let mut s = state(true, false);
        s.version = Some("1.0.4".into());
        s.version_ok = Some(false);
        d.apply_state(s);
        match d.phase() {
            Phase::Blocked { reason } => {
                assert!(reason.contains("1.0.4"), "got {}", reason);
                assert!(reason.contains("claude update"), "got {}", reason);
            }
            other => panic!("expected Blocked, got {:?}", other),
        }
    }

    #[test]
    fn a_successful_sign_in_shows_the_account_before_it_closes() {
        let mut d = ClaudeLogin::new();
        assert_eq!(
            d.apply_state(state(true, true)),
            None,
            "closing on the reading itself is what left the owner unsure which account was connected"
        );
        assert_eq!(*d.phase(), Phase::Connected);
        assert_eq!(
            d.handle_key(key(KeyCode::Enter)),
            Some(ClaudeLoginAction::Connected)
        );
    }

    #[test]
    fn backing_out_of_the_success_screen_does_not_silently_select_the_provider() {
        let mut d = ClaudeLogin::new();
        d.apply_state(state(true, true));
        assert_eq!(d.handle_key(key(KeyCode::Esc)), Some(ClaudeLoginAction::Cancel));
    }

    #[test]
    fn the_connected_screen_names_email_org_and_plan_not_just_the_email() {
        let s = state(true, true);
        let lines = account_lines(Some(&s));
        assert_eq!(lines[0], ("Account", "luna@example.com".to_string()));
        assert_eq!(lines[1], ("Org", "Acme Inc".to_string()));
        assert_eq!(lines[2], ("Plan", "max".to_string()));
    }

    #[test]
    fn a_plan_the_cli_did_not_report_says_so_rather_than_showing_a_dash() {
        let mut s = state(true, true);
        s.plan = None;
        let lines = account_lines(Some(&s));
        assert_eq!(lines[2], ("Plan", "not reported".to_string()));
    }

    #[test]
    fn an_absent_org_reads_as_personal_which_is_what_it_means() {
        let mut s = state(true, true);
        s.org = None;
        let lines = account_lines(Some(&s));
        assert_eq!(lines[1], ("Org", "personal".to_string()));
    }

    #[test]
    fn a_child_exiting_zero_is_not_treated_as_a_successful_sign_in() {
        let mut d = ClaudeLogin::new();
        d.apply_state(state(true, false));
        d.pane = Some(PtyPane::spawn("/bin/true", &[], &[], 10, 40));
        d.phase = Phase::Running { install: false };

        let mut action = None;
        for _ in 0..200 {
            action = d.tick();
            if action.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(25));
        }
        assert_eq!(
            action,
            Some(ClaudeLoginAction::Refresh),
            "an exit code is not a credential — the binary has to be re-asked"
        );
        assert_eq!(*d.phase(), Phase::Verifying);
    }

    #[test]
    fn a_reading_that_arrives_mid_run_does_not_yank_the_screen_from_the_child() {
        let mut d = ClaudeLogin::new();
        d.apply_state(state(true, false));
        d.pane = Some(PtyPane::spawn("/bin/cat", &[], &[], 10, 40));
        d.phase = Phase::Running { install: false };

        assert_eq!(d.apply_state(state(true, false)), None);
        assert!(matches!(d.phase(), Phase::Running { .. }));
    }

    #[test]
    fn keys_go_to_the_child_while_it_runs_including_esc() {
        let mut d = ClaudeLogin::new();
        d.apply_state(state(true, false));
        d.pane = Some(PtyPane::spawn("/bin/cat", &[], &[], 10, 40));
        d.phase = Phase::Running { install: false };

        assert_eq!(
            d.handle_key(key(KeyCode::Esc)),
            None,
            "Esc belongs to Claude Code's own menus while it is running"
        );
        assert!(matches!(d.phase(), Phase::Running { .. }));
    }

    #[test]
    fn ctrl_bracket_stops_a_running_child_instead_of_being_typed_at_it() {
        let mut d = ClaudeLogin::new();
        d.apply_state(state(true, false));
        d.pane = Some(PtyPane::spawn("/bin/cat", &[], &[], 10, 40));
        d.phase = Phase::Running { install: false };

        assert_eq!(
            d.handle_key(KeyEvent::new(KeyCode::Char(']'), KeyModifiers::CONTROL)),
            None
        );
        assert_eq!(*d.phase(), Phase::Verifying);
    }

    #[test]
    fn esc_backs_out_when_nothing_is_running() {
        let mut d = ClaudeLogin::new();
        d.apply_state(state(true, false));
        assert_eq!(d.handle_key(key(KeyCode::Esc)), Some(ClaudeLoginAction::Cancel));
    }

    #[test]
    fn a_failed_fetch_says_nothing_about_the_binary_it_never_reached() {
        let mut d = ClaudeLogin::new();
        d.apply_fetch_error("connection refused".into());
        match d.phase() {
            Phase::Blocked { reason } => assert!(reason.contains("connection refused")),
            other => panic!("expected Blocked, got {:?}", other),
        }
        assert!(
            d.state().is_none(),
            "nothing was learned, so nothing may be asserted"
        );
    }

    #[test]
    fn dropping_the_dialog_stops_its_repaint_ticker() {
        let d = ClaudeLogin::new();
        let alive = Arc::clone(&d.alive);
        assert!(alive.load(Ordering::Relaxed));
        drop(d);
        assert!(!alive.load(Ordering::Relaxed));
    }
}
