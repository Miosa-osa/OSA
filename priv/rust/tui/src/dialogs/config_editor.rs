// Phase 2+: config editor — some helpers wired as the surface matures.
#![allow(dead_code)]

//! Unified `/config` surface — a full-screen, navigable settings editor.
//!
//! Rows cover provider, model, reasoning effort, theme, default permission mode,
//! notifications, and sandbox backend, plus a free-text API base-URL row. Enum
//! rows cycle in place; the bool row toggles; the text row opens an inline edit
//! buffer; the provider/model rows defer to the existing model picker.
//!
//! The dialog is self-contained: `handle_key` mutates local state and returns a
//! [`ConfigAction`] the app layer applies (persisting to `~/.osa/.env`, the
//! backend, or live UI state). `Esc` closes.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    prelude::*,
    widgets::{Block, BorderType, Borders, Clear, Paragraph},
};

// ── Field identity ──────────────────────────────────────────────────────────

/// Which setting a row edits. Used by the app layer to route persistence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigField {
    Provider,
    Model,
    ReasoningEffort,
    Theme,
    PermissionMode,
    Notifications,
    SandboxBackend,
    ApiBaseUrl,
}

impl ConfigField {
    fn label(self) -> &'static str {
        match self {
            ConfigField::Provider => "Provider",
            ConfigField::Model => "Model",
            ConfigField::ReasoningEffort => "Reasoning effort",
            ConfigField::Theme => "Theme",
            ConfigField::PermissionMode => "Permission mode",
            ConfigField::Notifications => "Notifications",
            ConfigField::SandboxBackend => "Sandbox backend",
            ConfigField::ApiBaseUrl => "API base URL",
        }
    }

    fn hint(self) -> &'static str {
        match self {
            ConfigField::Provider => "Enter: open model picker",
            ConfigField::Model => "Enter: open model picker",
            ConfigField::ReasoningEffort => "Enter/→: cycle effort",
            ConfigField::Theme => "Enter/→: cycle theme",
            ConfigField::PermissionMode => "Enter/→: cycle mode",
            ConfigField::Notifications => "Enter: toggle on/off",
            ConfigField::SandboxBackend => "Enter/→: cycle backend",
            ConfigField::ApiBaseUrl => "Enter: edit text",
        }
    }
}

// ── Row kinds ───────────────────────────────────────────────────────────────

enum RowKind {
    /// Cycles through a fixed set of option strings.
    Enum {
        options: Vec<String>,
        index: usize,
    },
    /// On/off toggle.
    Bool(bool),
    /// Free-text string, edited inline.
    Text(String),
    /// Defers to an external picker (no in-place value; shows a live snapshot).
    Action {
        display: String,
    },
}

struct Row {
    field: ConfigField,
    kind: RowKind,
}

impl Row {
    fn value_str(&self) -> String {
        match &self.kind {
            RowKind::Enum { options, index } => {
                options.get(*index).cloned().unwrap_or_default()
            }
            RowKind::Bool(b) => if *b { "on".into() } else { "off".into() },
            RowKind::Text(s) => {
                if s.is_empty() {
                    "(default)".into()
                } else {
                    s.clone()
                }
            }
            RowKind::Action { display } => {
                if display.is_empty() {
                    "(not set)".into()
                } else {
                    display.clone()
                }
            }
        }
    }
}

// ── Action ──────────────────────────────────────────────────────────────────

/// Result of a keypress that the app layer must act on.
#[derive(Debug, Clone)]
pub enum ConfigAction {
    /// Close the editor (Esc).
    Close,
    /// Open the model picker to choose provider/model.
    OpenModelPicker,
    /// A value was committed; persist + apply it. `value` is the new string
    /// (for `Notifications` it is "on"/"off").
    SetValue {
        field: ConfigField,
        value: String,
    },
}

// ── Snapshot passed in at construction ──────────────────────────────────────

/// Current settings snapshot used to seed the editor. The app layer fills this
/// from `Config`, the status bar, the header, and `~/.osa/.env`.
pub struct ConfigSnapshot {
    pub provider: String,
    pub model: String,
    pub reasoning_effort: String,
    pub theme: String,
    pub permission_mode: String,
    pub notifications: bool,
    pub sandbox_backend: String,
    pub api_base_url: String,
    pub themes: Vec<String>,
}

// ── State ───────────────────────────────────────────────────────────────────

pub struct ConfigEditor {
    rows: Vec<Row>,
    cursor: usize,
    /// When `Some`, we are editing the text row; the buffer holds keystrokes.
    editing: Option<String>,
}

const REASONING_LEVELS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];
const PERMISSION_MODES: [&str; 5] = ["default", "auto", "acceptEdits", "plan", "bypass"];
const SANDBOX_BACKENDS: [&str; 5] = ["miosa", "e2b", "vercel", "local", "none"];

fn enum_row(field: ConfigField, options: &[&str], current: &str) -> Row {
    let options: Vec<String> = options.iter().map(|s| s.to_string()).collect();
    let index = options
        .iter()
        .position(|o| o.eq_ignore_ascii_case(current))
        .unwrap_or(0);
    Row {
        field,
        kind: RowKind::Enum { options, index },
    }
}

impl ConfigEditor {
    pub fn new(snap: ConfigSnapshot) -> Self {
        let themes: Vec<&str> = snap.themes.iter().map(|s| s.as_str()).collect();
        let rows = vec![
            Row {
                field: ConfigField::Provider,
                kind: RowKind::Action { display: snap.provider },
            },
            Row {
                field: ConfigField::Model,
                kind: RowKind::Action { display: snap.model },
            },
            enum_row(
                ConfigField::ReasoningEffort,
                &REASONING_LEVELS,
                &snap.reasoning_effort,
            ),
            enum_row(ConfigField::Theme, &themes, &snap.theme),
            enum_row(
                ConfigField::PermissionMode,
                &PERMISSION_MODES,
                &snap.permission_mode,
            ),
            Row {
                field: ConfigField::Notifications,
                kind: RowKind::Bool(snap.notifications),
            },
            enum_row(
                ConfigField::SandboxBackend,
                &SANDBOX_BACKENDS,
                &snap.sandbox_backend,
            ),
            Row {
                field: ConfigField::ApiBaseUrl,
                kind: RowKind::Text(snap.api_base_url),
            },
        ];
        Self {
            rows,
            cursor: 0,
            editing: None,
        }
    }

    fn current_field(&self) -> ConfigField {
        self.rows[self.cursor].field
    }

    // ── Key handling ─────────────────────────────────────────────────────────

    pub fn handle_key(&mut self, key: KeyEvent) -> Option<ConfigAction> {
        // In text-edit mode the buffer owns keystrokes.
        if self.editing.is_some() {
            return self.handle_edit_key(key);
        }

        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            // Allow Ctrl+C to close, ignore other modified keys.
            if key.code == KeyCode::Char('c') {
                return Some(ConfigAction::Close);
            }
            return None;
        }

        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => Some(ConfigAction::Close),
            KeyCode::Up | KeyCode::Char('k') => {
                self.cursor = self.cursor.checked_sub(1).unwrap_or(self.rows.len() - 1);
                None
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.cursor = (self.cursor + 1) % self.rows.len();
                None
            }
            // Left cycles enums backwards; ignored for other kinds.
            KeyCode::Left | KeyCode::Char('h') => self.cycle(false),
            // Right / Enter / Space activate the row.
            KeyCode::Right | KeyCode::Char('l') => self.cycle(true),
            KeyCode::Enter | KeyCode::Char(' ') => self.activate(),
            _ => None,
        }
    }

    /// Activate the current row: cycle enums forward, toggle bools, open picker
    /// for provider/model, or enter text-edit mode.
    fn activate(&mut self) -> Option<ConfigAction> {
        let field = self.current_field();
        match &mut self.rows[self.cursor].kind {
            RowKind::Action { .. } => match field {
                ConfigField::Provider | ConfigField::Model => {
                    Some(ConfigAction::OpenModelPicker)
                }
                _ => None,
            },
            RowKind::Bool(b) => {
                *b = !*b;
                let value = if *b { "on" } else { "off" };
                Some(ConfigAction::SetValue {
                    field,
                    value: value.to_string(),
                })
            }
            RowKind::Enum { .. } => self.cycle(true),
            RowKind::Text(s) => {
                self.editing = Some(s.clone());
                None
            }
        }
    }

    /// Cycle an enum row (`forward` = next, else previous). No-op for non-enums.
    fn cycle(&mut self, forward: bool) -> Option<ConfigAction> {
        let field = self.current_field();
        if let RowKind::Enum { options, index } = &mut self.rows[self.cursor].kind {
            if options.is_empty() {
                return None;
            }
            let len = options.len();
            *index = if forward {
                (*index + 1) % len
            } else {
                (*index + len - 1) % len
            };
            let value = options[*index].clone();
            return Some(ConfigAction::SetValue { field, value });
        }
        None
    }

    /// Key handling while the inline text editor is active.
    fn handle_edit_key(&mut self, key: KeyEvent) -> Option<ConfigAction> {
        let Some(buf) = self.editing.as_mut() else {
            return None;
        };
        match key.code {
            KeyCode::Esc => {
                // Cancel — discard the edit.
                self.editing = None;
                None
            }
            KeyCode::Enter => {
                let value = self.editing.take().unwrap_or_default();
                let field = self.current_field();
                if let RowKind::Text(s) = &mut self.rows[self.cursor].kind {
                    *s = value.clone();
                }
                Some(ConfigAction::SetValue { field, value })
            }
            KeyCode::Backspace => {
                buf.pop();
                None
            }
            KeyCode::Char(c)
                if !key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                buf.push(c);
                None
            }
            _ => None,
        }
    }

    // ── Drawing ───────────────────────────────────────────────────────────────

    pub fn draw(&self, frame: &mut Frame, area: Rect) {
        let theme = crate::style::theme();

        frame.render_widget(Clear, area);
        let block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(theme.colors.primary))
            .style(Style::default().bg(theme.colors.dialog_bg));
        frame.render_widget(block, area);

        let inner = Rect::new(
            area.x + 2,
            area.y + 1,
            area.width.saturating_sub(4),
            area.height.saturating_sub(2),
        );
        if inner.height < 5 {
            return;
        }

        let mut cy = inner.y;

        // Title.
        frame.render_widget(
            Paragraph::new("Configuration")
                .style(theme.dialog_title())
                .alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Subtitle / store path.
        frame.render_widget(
            Paragraph::new("Settings persist to ~/.osa/.env and tui.json")
                .style(Style::default().fg(theme.colors.dim))
                .alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;

        // Separator.
        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(sep.as_str()).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 2;

        let label_w: usize = 18;

        // Rows.
        for (i, row) in self.rows.iter().enumerate() {
            let bottom_guard = inner.y + inner.height.saturating_sub(2);
            if cy >= bottom_guard {
                break;
            }

            let is_cursor = i == self.cursor;
            let is_editing = is_cursor && self.editing.is_some();

            let cursor_char = if is_cursor { "▸" } else { " " };
            let label_style = if is_cursor {
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(theme.colors.muted)
            };

            // Value rendering — editing shows the live buffer + a caret.
            let (value_text, value_style) = if is_editing {
                let buf = self.editing.clone().unwrap_or_default();
                (
                    format!("{}▏", buf),
                    Style::default()
                        .fg(theme.colors.warning)
                        .add_modifier(Modifier::BOLD),
                )
            } else {
                let vstyle = if is_cursor {
                    Style::default().fg(theme.colors.success)
                } else {
                    Style::default().fg(theme.colors.secondary)
                };
                (row.value_str(), vstyle)
            };

            let spans = vec![
                Span::styled(format!("{} ", cursor_char), label_style),
                Span::styled(
                    format!("{:<width$}", row.field.label(), width = label_w),
                    label_style,
                ),
                Span::styled(value_text, value_style),
            ];
            frame.render_widget(
                Paragraph::new(Line::from(spans)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;
        }

        // Per-row hint above the help line.
        let hint_y = inner.y + inner.height.saturating_sub(2);
        let hint = if self.editing.is_some() {
            "Type to edit  •  Enter save  •  Esc cancel".to_string()
        } else {
            self.rows[self.cursor].field.hint().to_string()
        };
        frame.render_widget(
            Paragraph::new(hint)
                .style(Style::default().fg(theme.colors.dim))
                .alignment(Alignment::Center),
            Rect::new(inner.x, hint_y, inner.width, 1),
        );

        // Help line.
        let help_y = inner.y + inner.height.saturating_sub(1);
        let help = Line::from(vec![
            Span::styled("↑↓", theme.dialog_help_key()),
            Span::styled(" move  ", theme.dialog_help()),
            Span::styled("←→", theme.dialog_help_key()),
            Span::styled(" change  ", theme.dialog_help()),
            Span::styled("Enter", theme.dialog_help_key()),
            Span::styled(" edit  ", theme.dialog_help()),
            Span::styled("Esc", theme.dialog_help_key()),
            Span::styled(" close", theme.dialog_help()),
        ]);
        frame.render_widget(
            Paragraph::new(help).alignment(Alignment::Center),
            Rect::new(inner.x, help_y, inner.width, 1),
        );
    }
}
