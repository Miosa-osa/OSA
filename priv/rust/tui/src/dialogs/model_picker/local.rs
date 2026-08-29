//! Local model catalog screens inside the model picker.
//!
//! Four modes layered on the picker's state machine:
//!
//! * `LocalCatalog`    — installed models, then the curated catalog, each with
//!                       a fit badge for THIS machine, tok/s, capabilities.
//! * `LocalLoading`    — a fetch is in flight (catalog or one model's detail).
//! * `LocalDetail`     — one model: quant ladder with size + fit + est. tok/s;
//!                       pick a quant and install, or use it if installed.
//! * `LocalInstalling` — the pull, with a progress bar, then the benchmark
//!                       result and a one-key "use it now".
//!
//! The backend does the thinking (`/models/local*`); this file only asks,
//! shows, and asks again. Every inbound setter is guarded on the mode, like
//! `set_provider_models`, so a late reply cannot yank the user off a screen
//! they already left.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::{prelude::*, widgets::Paragraph};

use super::{ModelPicker, ModelPickerAction, PickerMode};
use crate::client::types::{LocalInstallJob, LocalModelInfo, LocalModelRow, LocalModelsResponse};

const LOCAL_BASE_URL: &str = "http://localhost:11434";

/// What a row in the catalog list refers to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum LocalRow {
    Header(&'static str),
    Installed(usize),
    Catalog(usize),
}

impl ModelPicker {
    // ── entry / exit ─────────────────────────────────────────────────────────

    /// Open the catalog from wherever the picker is; `Esc` returns there.
    pub(super) fn open_local_catalog(&mut self) -> Option<ModelPickerAction> {
        self.local_return = self.mode;
        self.local_error = None;
        self.local_pending_delete = None;
        self.mode = PickerMode::LocalLoading;
        Some(ModelPickerAction::LoadLocalCatalog)
    }

    fn leave_local(&mut self) {
        self.mode = match self.local_return {
            PickerMode::Models => PickerMode::Models,
            _ => PickerMode::Providers,
        };
        self.filter.clear();
    }

    // ── inbound ──────────────────────────────────────────────────────────────

    pub fn set_local_catalog(&mut self, result: Result<LocalModelsResponse, String>) {
        if !matches!(
            self.mode,
            PickerMode::LocalLoading | PickerMode::LocalCatalog | PickerMode::LocalInstalling
        ) {
            return;
        }
        match result {
            Ok(resp) => {
                self.local_error = resp.error.clone();
                self.local = Some(resp);
                let rows = self.local_rows();
                if self.local_cursor >= rows.len() {
                    self.local_cursor = 0;
                }
                self.local_cursor = Self::first_selectable(&rows, self.local_cursor);
                if self.mode != PickerMode::LocalInstalling {
                    self.mode = PickerMode::LocalCatalog;
                }
            }
            Err(e) => {
                self.local_error = Some(e);
                if self.local.is_none() {
                    self.local = Some(LocalModelsResponse::default());
                }
                if self.mode == PickerMode::LocalLoading {
                    self.mode = PickerMode::LocalCatalog;
                }
            }
        }
    }

    pub fn set_local_info(&mut self, result: Result<LocalModelInfo, String>) {
        if self.mode != PickerMode::LocalLoading {
            return;
        }
        match result {
            Ok(info) => {
                // Cursor starts on the recommended quant.
                let want = info.quant.clone().unwrap_or_default().to_uppercase();
                self.local_quant_cursor = info
                    .quants
                    .iter()
                    .position(|q| q.quant.to_uppercase() == want)
                    .unwrap_or(0);
                self.local_info = Some(info);
                self.local_error = None;
                self.mode = PickerMode::LocalDetail;
            }
            Err(e) => {
                self.local_error = Some(e);
                self.mode = PickerMode::LocalCatalog;
            }
        }
    }

    pub fn set_local_job(&mut self, result: Result<LocalInstallJob, String>) {
        if self.mode != PickerMode::LocalInstalling {
            return;
        }
        match result {
            Ok(job) => self.local_job = Some(job),
            Err(e) => {
                // A single failed poll is not a failed pull; keep the last
                // known job but show the transport error.
                self.local_error = Some(e);
            }
        }
    }

    pub fn set_local_removed(&mut self, result: Result<String, String>) {
        match result {
            Ok(_) => self.local_error = None,
            Err(e) => self.local_error = Some(e),
        }
        self.local_pending_delete = None;
    }

    // ── rows ─────────────────────────────────────────────────────────────────

    pub(super) fn local_rows(&self) -> Vec<LocalRow> {
        let mut rows = Vec::new();
        if let Some(l) = self.local.as_ref() {
            if !l.installed.is_empty() {
                rows.push(LocalRow::Header("Installed"));
                for i in 0..l.installed.len() {
                    rows.push(LocalRow::Installed(i));
                }
            }
            if !l.catalog.is_empty() {
                rows.push(LocalRow::Header("Available — curated abliterated / uncensored"));
                for i in 0..l.catalog.len() {
                    rows.push(LocalRow::Catalog(i));
                }
            }
        }
        rows
    }

    fn first_selectable(rows: &[LocalRow], from: usize) -> usize {
        (from..rows.len())
            .chain(0..from)
            .find(|&i| !matches!(rows[i], LocalRow::Header(_)))
            .unwrap_or(0)
    }

    fn row_model(&self, row: LocalRow) -> Option<&LocalModelRow> {
        let l = self.local.as_ref()?;
        match row {
            LocalRow::Installed(i) => l.installed.get(i),
            LocalRow::Catalog(i) => l.catalog.get(i),
            LocalRow::Header(_) => None,
        }
    }

    fn move_local_cursor(&mut self, delta: isize) {
        let rows = self.local_rows();
        if rows.is_empty() {
            return;
        }
        let mut i = self.local_cursor as isize;
        loop {
            i += delta;
            if i < 0 || i as usize >= rows.len() {
                return;
            }
            if !matches!(rows[i as usize], LocalRow::Header(_)) {
                self.local_cursor = i as usize;
                break;
            }
        }
        let visible = self.list_height();
        if self.local_cursor < self.local_scroll {
            self.local_scroll = self.local_cursor;
        } else if self.local_cursor >= self.local_scroll + visible {
            self.local_scroll = self.local_cursor - visible + 1;
        }
    }

    fn select_action(model: &str) -> ModelPickerAction {
        ModelPickerAction::SelectModel {
            provider: "ollama_local".to_string(),
            runtime_provider: "ollama".to_string(),
            model: model.to_string(),
            base_url: Some(LOCAL_BASE_URL.to_string()),
        }
    }

    // ── keys ─────────────────────────────────────────────────────────────────

    pub(super) fn handle_local_loading_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        if key.code == KeyCode::Esc {
            if self.local.is_some() {
                self.mode = PickerMode::LocalCatalog;
            } else {
                self.leave_local();
            }
        }
        None
    }

    pub(super) fn handle_local_catalog_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }
        let rows = self.local_rows();
        let current = rows.get(self.local_cursor).copied();
        match key.code {
            KeyCode::Esc => {
                if self.local_pending_delete.take().is_some() {
                    return None;
                }
                self.leave_local();
            }
            KeyCode::Up | KeyCode::Char('k') => self.move_local_cursor(-1),
            KeyCode::Down | KeyCode::Char('j') => self.move_local_cursor(1),
            KeyCode::Char('r') => {
                self.mode = PickerMode::LocalLoading;
                return Some(ModelPickerAction::LoadLocalCatalog);
            }
            KeyCode::Enter => {
                let row = current?;
                let m = self.row_model(row)?.clone();
                if m.installed {
                    return Some(Self::select_action(&m.tag));
                }
                let reff = m.catalog_id.clone().unwrap_or(m.tag.clone());
                self.mode = PickerMode::LocalLoading;
                return Some(ModelPickerAction::LoadLocalInfo { reff });
            }
            KeyCode::Char('i') | KeyCode::Char(' ') => {
                let row = current?;
                let m = self.row_model(row)?.clone();
                let reff = if m.installed {
                    m.tag.clone()
                } else {
                    m.catalog_id.clone().unwrap_or(m.tag.clone())
                };
                self.mode = PickerMode::LocalLoading;
                return Some(ModelPickerAction::LoadLocalInfo { reff });
            }
            KeyCode::Char('d') | KeyCode::Delete => {
                let row = current?;
                let m = self.row_model(row)?.clone();
                if !m.installed {
                    return None;
                }
                // Two presses: the first arms, the second fires. A model is a
                // 17 GB download; one stray key must not be able to delete it.
                if self.local_pending_delete.as_deref() == Some(m.tag.as_str()) {
                    self.local_pending_delete = None;
                    return Some(ModelPickerAction::RemoveLocal { tag: m.tag });
                }
                self.local_pending_delete = Some(m.tag);
            }
            _ => {}
        }
        None
    }

    pub(super) fn handle_local_detail_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        if key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) {
            return None;
        }
        let info = self.local_info.clone()?;
        match key.code {
            KeyCode::Esc => {
                self.local_error = None;
                self.mode = if self.local.is_some() {
                    PickerMode::LocalCatalog
                } else {
                    PickerMode::LocalLoading
                };
                if self.mode == PickerMode::LocalLoading {
                    return Some(ModelPickerAction::LoadLocalCatalog);
                }
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.local_quant_cursor = self.local_quant_cursor.saturating_sub(1);
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.local_quant_cursor + 1 < info.quants.len() {
                    self.local_quant_cursor += 1;
                }
            }
            KeyCode::Enter => {
                if info.installed {
                    return Some(Self::select_action(&info.tag));
                }
                let quant = info.quants.get(self.local_quant_cursor).cloned();
                if let Some(q) = quant.as_ref() {
                    if q.fit.as_ref().map(|f| f.verdict.as_str()) == Some("no") {
                        self.local_error =
                            Some(format!("{} won't fit this machine — pick a smaller quant", q.quant));
                        return None;
                    }
                }
                let reff = info.catalog_id.clone().unwrap_or(info.tag.clone());
                self.local_job = None;
                self.local_error = None;
                self.mode = PickerMode::LocalInstalling;
                return Some(ModelPickerAction::InstallLocal {
                    reff,
                    quant: quant.map(|q| q.quant),
                });
            }
            _ => {}
        }
        None
    }

    pub(super) fn handle_local_installing_key(&mut self, key: KeyEvent) -> Option<ModelPickerAction> {
        let job = self.local_job.clone();
        match key.code {
            KeyCode::Esc => {
                // The pull keeps running on the backend; leaving the screen
                // just stops watching it. The catalog will show it installed
                // once it lands.
                self.mode = PickerMode::LocalLoading;
                return Some(ModelPickerAction::LoadLocalCatalog);
            }
            KeyCode::Enter => {
                if let Some(j) = job {
                    if j.state == "done" {
                        if let Some(tag) = j.tag {
                            return Some(Self::select_action(&tag));
                        }
                    }
                }
            }
            _ => {}
        }
        None
    }

    // ── drawing ──────────────────────────────────────────────────────────────

    fn fit_badge(fit: Option<&crate::client::types::LocalFit>, theme: &crate::style::Theme) -> Span<'static> {
        match fit.map(|f| f.verdict.as_str()) {
            Some("fits") => Span::styled("✓", Style::default().fg(theme.colors.success)),
            Some("partial") | Some("cpu") => Span::styled("⚠", Style::default().fg(theme.colors.warning)),
            Some("no") => Span::styled("✗", Style::default().fg(theme.colors.error)),
            _ => Span::styled("·", Style::default().fg(theme.colors.dim)),
        }
    }

    fn fit_label(verdict: &str) -> &'static str {
        match verdict {
            "fits" => "fits in VRAM",
            "partial" => "partial offload (slow)",
            "cpu" => "CPU only",
            "no" => "won't fit",
            _ => "?",
        }
    }

    fn gb(bytes: u64) -> String {
        format!("{:.1} GB", bytes as f64 / 1e9)
    }

    fn row_summary(m: &LocalModelRow) -> String {
        let mut parts: Vec<String> = Vec::new();
        if m.size_bytes > 0 {
            let approx = if m.installed { "" } else { "~" };
            parts.push(format!("{}{}", approx, Self::gb(m.size_bytes)));
        }
        if let Some(q) = m.quant.as_ref() {
            parts.push(q.clone());
        }
        if let Some(p) = m.params.as_ref() {
            parts.push(p.clone());
        }
        if let Some(f) = m.fit.as_ref() {
            parts.push(Self::fit_label(&f.verdict).to_string());
        }
        if let Some(t) = m.measured_tps {
            parts.push(format!("{:.0} tok/s measured", t));
        } else if let Some(t) = m.fit.as_ref().and_then(|f| f.est_tps) {
            parts.push(format!("~{:.0} tok/s est.", t));
        }
        if !m.capabilities.is_empty() {
            parts.push(m.capabilities.join(", "));
        }
        parts.join(" · ")
    }

    fn draw_local_title(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme, title: &str) -> u16 {
        let mut cy = inner.y;
        frame.render_widget(
            Paragraph::new(title.to_string())
                .style(theme.dialog_title())
                .alignment(Alignment::Center),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy += 1;
        let hw = self
            .local
            .as_ref()
            .map(|l| l.hardware.summary.clone())
            .unwrap_or_default();
        if !hw.is_empty() {
            let ctx = self.local.as_ref().map(|l| l.ctx).unwrap_or(0);
            let line = if ctx > 0 {
                format!("  {} · fit at {}K ctx", hw, ctx / 1024)
            } else {
                format!("  {}", hw)
            };
            frame.render_widget(
                Paragraph::new(line).style(Style::default().fg(theme.colors.secondary)),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;
        }
        let sep = "─".repeat(inner.width as usize);
        frame.render_widget(
            Paragraph::new(sep).style(Style::default().fg(theme.colors.dim)),
            Rect::new(inner.x, cy, inner.width, 1),
        );
        cy + 1
    }

    fn draw_local_error(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        if let Some(e) = self.local_error.as_ref() {
            let y = inner.y + inner.height.saturating_sub(2);
            frame.render_widget(
                Paragraph::new(Span::styled(
                    format!(" {}", e),
                    Style::default().fg(theme.colors.warning),
                )),
                Rect::new(inner.x, y, inner.width, 1),
            );
        }
    }

    pub(super) fn draw_local_loading(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let cy = self.draw_local_title(frame, inner, theme, "Local models");
        let body_h = inner.height.saturating_sub(cy - inner.y + 1);
        frame.render_widget(
            Paragraph::new(Span::styled(
                "Checking what fits this machine…",
                Style::default().fg(theme.colors.secondary),
            ))
            .alignment(Alignment::Center),
            Rect::new(inner.x, cy + body_h / 2, inner.width, 1),
        );
        self.draw_help(frame, inner, theme, &[("Esc", "back")]);
    }

    pub(super) fn draw_local_catalog(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let cy = self.draw_local_title(frame, inner, theme, "Local models");
        let rows = self.local_rows();
        // Two lines per model row (name, then summary) so the summary never
        // fights the name for width.
        let list_h = inner.height.saturating_sub(cy - inner.y + 2) as usize;
        let per_row = 2usize;
        let visible_rows = (list_h / per_row).max(1);
        self.list_viewport.set(visible_rows);
        let scroll = super::super::clamp_scroll_to_cursor(self.local_scroll, self.local_cursor, visible_rows);

        if rows.is_empty() {
            let msg = if self.local_error.is_some() {
                "Ollama is not reachable — start it and press r"
            } else {
                "No local models and an empty catalog"
            };
            frame.render_widget(
                Paragraph::new(Span::styled(msg, Style::default().fg(theme.colors.muted)))
                    .alignment(Alignment::Center),
                Rect::new(inner.x, cy + (list_h as u16) / 2, inner.width, 1),
            );
        }

        let mut y = cy;
        for abs in scroll..rows.len() {
            if (y - cy) as usize + per_row > list_h {
                break;
            }
            match rows[abs] {
                LocalRow::Header(h) => {
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            format!(" {}", h),
                            Style::default().fg(theme.colors.secondary).add_modifier(Modifier::BOLD),
                        )),
                        Rect::new(inner.x, y, inner.width, 1),
                    );
                    y += 1;
                }
                row => {
                    let Some(m) = self.row_model(row) else { continue };
                    let selected = abs == self.local_cursor;
                    let name_style = if selected {
                        Style::default().fg(theme.colors.primary).add_modifier(Modifier::BOLD)
                    } else {
                        Style::default().fg(theme.colors.muted)
                    };
                    let cursor = if selected { "▸" } else { " " };
                    let mut spans = vec![
                        Span::styled(format!("{} ", cursor), name_style),
                        Self::fit_badge(m.fit.as_ref(), theme),
                        Span::styled(" ", name_style),
                    ];
                    let label = match (&m.catalog_id, m.installed) {
                        (Some(id), false) => format!("{}  ", id),
                        _ => format!("{}  ", m.tag),
                    };
                    spans.push(Span::styled(label, name_style));
                    if m.installed && m.name != m.tag {
                        spans.push(Span::styled(m.name.clone(), Style::default().fg(theme.colors.dim)));
                    } else if !m.installed {
                        spans.push(Span::styled(m.name.clone(), Style::default().fg(theme.colors.dim)));
                    }
                    if m.loaded {
                        spans.push(Span::styled("  ● in VRAM", Style::default().fg(theme.colors.success)));
                    }
                    if self.local_pending_delete.as_deref() == Some(m.tag.as_str()) {
                        spans.push(Span::styled(
                            "  press d again to delete",
                            Style::default().fg(theme.colors.error),
                        ));
                    }
                    frame.render_widget(
                        Paragraph::new(Line::from(spans)),
                        Rect::new(inner.x, y, inner.width, 1),
                    );
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            format!("      {}", Self::row_summary(m)),
                            Style::default().fg(theme.colors.dim),
                        )),
                        Rect::new(inner.x, y + 1, inner.width, 1),
                    );
                    y += 2;
                }
            }
        }

        self.draw_local_error(frame, inner, theme);
        self.draw_help(
            frame,
            inner,
            theme,
            &[
                ("↑↓", "nav"),
                ("Enter", "use / details"),
                ("i", "info"),
                ("d", "delete"),
                ("r", "refresh"),
                ("Esc", "back"),
            ],
        );
    }

    pub(super) fn draw_local_detail(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let Some(info) = self.local_info.as_ref() else {
            return self.draw_local_loading(frame, inner, theme);
        };
        let mut cy = self.draw_local_title(frame, inner, theme, &info.name);
        let dim = Style::default().fg(theme.colors.dim);
        let text = Style::default().fg(theme.colors.muted);

        let mut lines: Vec<Line> = Vec::new();
        lines.push(Line::from(vec![
            Span::styled("  Tag         ", dim),
            Span::styled(info.tag.clone(), text),
        ]));
        let mut facts: Vec<String> = Vec::new();
        if let Some(p) = info.params.as_ref() {
            facts.push(p.clone());
        }
        if let Some(f) = info.family.as_ref() {
            facts.push(f.clone());
        }
        if let Some(c) = info.context_length {
            facts.push(format!("{}K ctx trained", c / 1024));
        }
        if !info.capabilities.is_empty() {
            facts.push(info.capabilities.join(", "));
        }
        lines.push(Line::from(vec![
            Span::styled("  Model       ", dim),
            Span::styled(facts.join(" · "), text),
        ]));
        if let Some(b) = info.blurb.as_ref() {
            if !b.is_empty() {
                lines.push(Line::from(Span::styled(format!("  {}", b), dim)));
            }
        }
        lines.push(Line::from(Span::styled(
            if info.installed { "  Installed on this machine" } else { "  Not installed" },
            Style::default().fg(if info.installed { theme.colors.success } else { theme.colors.muted }),
        )));
        for l in lines {
            frame.render_widget(Paragraph::new(l), Rect::new(inner.x, cy, inner.width, 1));
            cy += 1;
        }
        cy += 1;

        if info.installed {
            if let Some(f) = info.fit.as_ref() {
                let speed = info
                    .measured
                    .as_ref()
                    .and_then(|m| m.get("decode_tps"))
                    .and_then(|v| v.as_f64())
                    .map(|t| format!("{:.1} tok/s measured", t))
                    .or_else(|| f.est_tps.map(|t| format!("~{:.0} tok/s est.", t)))
                    .unwrap_or_default();
                frame.render_widget(
                    Paragraph::new(Line::from(vec![
                        Span::styled("  ", dim),
                        Self::fit_badge(Some(f), theme),
                        Span::styled(
                            format!(
                                " {} · weights {} + KV {} · {}",
                                Self::fit_label(&f.verdict),
                                Self::gb(f.weights_bytes),
                                Self::gb(f.kv_bytes),
                                speed
                            ),
                            text,
                        ),
                    ])),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
            }
        } else {
            frame.render_widget(
                Paragraph::new(Span::styled("  Pick a quant:", Style::default().fg(theme.colors.secondary))),
                Rect::new(inner.x, cy, inner.width, 1),
            );
            cy += 1;
            let avail = inner.height.saturating_sub(cy - inner.y + 2) as usize;
            let recommended = info.quant.clone().unwrap_or_default().to_uppercase();
            for (i, q) in info.quants.iter().enumerate().take(avail) {
                let selected = i == self.local_quant_cursor;
                let style = if selected {
                    Style::default().fg(theme.colors.primary).add_modifier(Modifier::BOLD)
                } else {
                    text
                };
                let est = q
                    .fit
                    .as_ref()
                    .and_then(|f| f.est_tps)
                    .map(|t| format!("~{:.0} tok/s", t))
                    .unwrap_or_else(|| "—".to_string());
                let verdict = q.fit.as_ref().map(|f| Self::fit_label(&f.verdict)).unwrap_or("?");
                let star = if q.quant.to_uppercase() == recommended { " ★" } else { "" };
                let approx = if q.exact { "" } else { "~" };
                frame.render_widget(
                    Paragraph::new(Line::from(vec![
                        Span::styled(format!("  {} ", if selected { "▸" } else { " " }), style),
                        Self::fit_badge(q.fit.as_ref(), theme),
                        Span::styled(
                            format!(
                                " {:<8} {:>9}  {:<22} {}{}",
                                q.quant,
                                format!("{}{}", approx, Self::gb(q.bytes)),
                                verdict,
                                est,
                                star
                            ),
                            style,
                        ),
                    ])),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 1;
            }
        }

        self.draw_local_error(frame, inner, theme);
        let help: &[(&str, &str)] = if info.installed {
            &[("Enter", "use this model"), ("Esc", "back")]
        } else {
            &[("↑↓", "quant"), ("Enter", "install"), ("Esc", "back")]
        };
        self.draw_help(frame, inner, theme, help);
    }

    pub(super) fn draw_local_installing(&self, frame: &mut Frame, inner: Rect, theme: &crate::style::Theme) {
        let name = self
            .local_info
            .as_ref()
            .map(|i| i.name.clone())
            .unwrap_or_else(|| "model".to_string());
        let mut cy = self.draw_local_title(frame, inner, theme, &format!("Installing {}", name));
        cy += 1;
        let text = Style::default().fg(theme.colors.muted);

        match self.local_job.as_ref() {
            None => {
                frame.render_widget(
                    Paragraph::new(Span::styled("  Starting pull…", text)),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
            }
            Some(job) => {
                let (label, pct) = match job.state.as_str() {
                    "pulling" if job.total > 0 => (
                        format!(
                            "  {}  {} / {}",
                            job.status,
                            Self::gb(job.completed),
                            Self::gb(job.total)
                        ),
                        (job.completed as f64 / job.total as f64).clamp(0.0, 1.0),
                    ),
                    "pulling" => (format!("  {}", job.status), 0.0),
                    "benchmarking" => ("  Downloaded — measuring tokens/sec…".to_string(), 1.0),
                    "done" => ("  Installed".to_string(), 1.0),
                    _ => (format!("  Failed: {}", job.error.clone().unwrap_or_default()), 0.0),
                };
                frame.render_widget(
                    Paragraph::new(Span::styled(label, text)),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 1;
                let bar_w = inner.width.saturating_sub(12) as usize;
                let filled = ((bar_w as f64) * pct).round() as usize;
                let bar = format!(
                    "  [{}{}] {:>3}%",
                    "█".repeat(filled),
                    "░".repeat(bar_w.saturating_sub(filled)),
                    (pct * 100.0).round() as u64
                );
                frame.render_widget(
                    Paragraph::new(Span::styled(
                        bar,
                        Style::default().fg(if job.state == "error" {
                            theme.colors.error
                        } else {
                            theme.colors.primary
                        }),
                    )),
                    Rect::new(inner.x, cy, inner.width, 1),
                );
                cy += 2;

                if job.state == "done" {
                    if let Some(b) = job.bench.as_ref() {
                        let prompt = b
                            .prompt_tps
                            .map(|p| format!(" · prompt {:.0} tok/s", p))
                            .unwrap_or_default();
                        frame.render_widget(
                            Paragraph::new(Line::from(vec![
                                Span::styled("  ✓ ", Style::default().fg(theme.colors.success)),
                                Span::styled(
                                    format!("{:.1} tok/s measured{}", b.decode_tps, prompt),
                                    Style::default().fg(theme.colors.success).add_modifier(Modifier::BOLD),
                                ),
                            ])),
                            Rect::new(inner.x, cy, inner.width, 1),
                        );
                        cy += 1;
                    }
                    frame.render_widget(
                        Paragraph::new(Span::styled(
                            format!("  {}", job.tag.clone().unwrap_or_default()),
                            Style::default().fg(theme.colors.dim),
                        )),
                        Rect::new(inner.x, cy, inner.width, 1),
                    );
                }
            }
        }

        self.draw_local_error(frame, inner, theme);
        let done = self.local_job.as_ref().map(|j| j.state == "done").unwrap_or(false);
        let help: &[(&str, &str)] = if done {
            &[("Enter", "use it now"), ("Esc", "back to list")]
        } else {
            &[("Esc", "back (pull keeps running)")]
        };
        self.draw_help(frame, inner, theme, help);
    }
}
