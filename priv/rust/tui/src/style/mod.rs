// Phase 2+: theme fields for sidebar and input theming, used progressively as components mature
#![allow(dead_code)]

pub mod gradient;
pub mod themes;

use ratatui::style::{Color, Modifier, Style};

/// Color palette for a theme
#[derive(Debug, Clone)]
pub struct ThemeColors {
    pub primary: Color,
    pub secondary: Color,
    pub success: Color,
    pub warning: Color,
    pub error: Color,
    pub muted: Color,
    pub dim: Color,
    pub border: Color,
    pub msg_border_user: Color,
    pub msg_border_agent: Color,
    pub msg_border_system: Color,
    pub msg_border_warning: Color,
    pub msg_border_error: Color,
    pub sidebar_bg: Color,
    pub modal_bg: Color,
    pub tooltip_bg: Color,
    pub input_bg: Color,
    pub selection_bg: Color,
    pub dialog_bg: Color,
    pub button_active_bg: Color,
    pub button_active_text: Color,
    pub grad_a: Color,
    pub grad_b: Color,
    // Diff colors (for file edit rendering)
    pub diff_del_bg: Color,
    pub diff_add_bg: Color,
    pub diff_del_highlight_fg: Color,
    pub diff_del_highlight_bg: Color,
    pub diff_add_highlight_fg: Color,
    pub diff_add_highlight_bg: Color,
}

/// Complete theme with all computed styles
#[derive(Debug, Clone)]
pub struct Theme {
    pub name: String,
    pub colors: ThemeColors,
}

impl Theme {
    // === Text Styles ===
    pub fn bold(&self) -> Style {
        Style::default().add_modifier(Modifier::BOLD)
    }

    pub fn faint(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    /// The QUIETEST text tier — one step below [`Self::faint`].
    ///
    /// The live region had only two weights (accent and `faint`), so a plan
    /// checklist, an activity line, an executing feed, a roster header and a
    /// roster tree all arrived on screen at the same visual weight and the eye
    /// had nothing to land on first. `recede` is the third rung of the ladder:
    /// structure that must be present but must never compete — tree connectors,
    /// "+N earlier" counts, elided path prefixes, section rules.
    ///
    /// Backed by `colors.dim`, which every shipped theme already defines
    /// separately from `colors.muted` ("hints, pending bullet, faint rules"), so
    /// this holds in light as well as dark without hardcoding a colour.
    pub fn recede(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    /// A horizontal rule / section separator. Quietest tier, by definition: a
    /// rule that is as bright as the content it separates is just more content.
    pub fn rule(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    pub fn error_text(&self) -> Style {
        Style::default()
            .fg(self.colors.error)
            .add_modifier(Modifier::BOLD)
    }

    // === Banner ===
    pub fn banner_title(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn banner_detail(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    // === Prompt ===
    pub fn prompt_char(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    // === Messages ===
    pub fn user_label(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn agent_label(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn msg_meta(&self) -> Style {
        Style::default()
            .fg(self.colors.muted)
            .add_modifier(Modifier::ITALIC)
    }

    // === Spinner/Activity ===
    pub fn spinner(&self) -> Style {
        Style::default().fg(self.colors.primary)
    }

    /// Light-blue accent for the live "thinking" indicator (spinner glyph + rotating
    /// verb) — deliberately distinct from the orange primary accent.
    pub fn spinner_verb(&self) -> Style {
        Style::default()
            .fg(Color::Rgb(147, 165, 255))
            .add_modifier(Modifier::BOLD)
    }

    pub fn tool_name(&self) -> Style {
        Style::default().fg(self.colors.secondary)
    }

    pub fn tool_duration(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn tool_arg(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    // === Tasks ===
    pub fn task_done(&self) -> Style {
        Style::default().fg(self.colors.success)
    }

    pub fn task_active(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn task_pending(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn task_failed(&self) -> Style {
        Style::default().fg(self.colors.error)
    }

    // === Status Bar ===
    pub fn status_bar(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn status_signal(&self) -> Style {
        Style::default().fg(self.colors.secondary)
    }

    /// Signal mode pill — colored background badge for Signal Theory display.
    pub fn signal_pill(&self) -> Style {
        Style::default()
            .fg(Color::Black)
            .bg(self.colors.secondary)
            .add_modifier(Modifier::BOLD)
    }

    /// Signal genre label — lighter complement to the pill.
    pub fn signal_genre(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn context_bar(&self) -> Style {
        Style::default().fg(self.colors.primary)
    }

    // === Plan ===
    pub fn plan_selected(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn plan_unselected(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    // === Agents ===
    pub fn agent_name(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::BOLD)
    }

    /// The `main` root roster node: green + bold. It is the home node the user
    /// always returns to, so both its `●` glyph and `main` label render green
    /// (CC-parity FleetView cue).
    pub fn agent_main(&self) -> Style {
        Style::default()
            .fg(self.colors.success)
            .add_modifier(Modifier::BOLD)
    }

    pub fn agent_role(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn role_tag(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::DIM)
    }

    pub fn model_tag(&self) -> Style {
        Style::default()
            .fg(self.colors.muted)
            .add_modifier(Modifier::DIM)
    }

    pub fn wave_label(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    // === Activity Prefixes ===
    pub fn prefix_active(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn prefix_done(&self) -> Style {
        Style::default()
            .fg(self.colors.success)
            .add_modifier(Modifier::BOLD)
    }

    pub fn prefix_thinking(&self) -> Style {
        Style::default()
            .fg(self.colors.warning)
            .add_modifier(Modifier::BOLD)
    }

    pub fn connector(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn hint(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    // === Welcome ===
    pub fn welcome_title(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn welcome_meta(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn welcome_cwd(&self) -> Style {
        Style::default().fg(self.colors.secondary)
    }

    pub fn welcome_tip(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    // === Tool Rendering ===
    pub fn tool_header(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn tool_output(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn tool_status_pending(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn tool_status_running(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn tool_status_success(&self) -> Style {
        Style::default()
            .fg(self.colors.success)
            .add_modifier(Modifier::BOLD)
    }

    pub fn tool_status_error(&self) -> Style {
        Style::default()
            .fg(self.colors.error)
            .add_modifier(Modifier::BOLD)
    }

    pub fn tool_status_cancel(&self) -> Style {
        Style::default().fg(self.colors.warning)
    }

    // === Diff ===
    pub fn diff_add(&self) -> Style {
        Style::default().fg(self.colors.success)
    }

    pub fn diff_remove(&self) -> Style {
        Style::default().fg(self.colors.error)
    }

    pub fn diff_context(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn diff_hunk_label(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::ITALIC)
    }

    // === Code ===
    pub fn code_block(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn file_path(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::UNDERLINED)
    }

    pub fn line_number(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    pub fn code_keyword(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn code_string(&self) -> Style {
        Style::default().fg(self.colors.success)
    }

    pub fn code_comment(&self) -> Style {
        Style::default()
            .fg(self.colors.muted)
            .add_modifier(Modifier::ITALIC)
    }

    // === Sidebar ===
    pub fn sidebar_title(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn sidebar_label(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn sidebar_value(&self) -> Style {
        Style::default().fg(self.colors.secondary)
    }

    pub fn sidebar_file_item(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn sidebar_separator(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    // === Thinking ===
    pub fn thinking_header(&self) -> Style {
        Style::default()
            .fg(self.colors.warning)
            .add_modifier(Modifier::BOLD)
    }

    pub fn thinking_content(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    // === Modal/Dialog ===
    pub fn modal_title(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn overlay_dim(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    pub fn dialog_title(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn dialog_help(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn dialog_help_key(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::BOLD)
    }

    // === Completions ===
    pub fn completion_normal(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn completion_selected(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .bg(self.colors.dim)
            .add_modifier(Modifier::BOLD)
    }

    pub fn completion_match(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn completion_category(&self) -> Style {
        Style::default()
            .fg(self.colors.warning)
            .add_modifier(Modifier::BOLD)
    }

    // === Buttons ===
    pub fn button_active(&self) -> Style {
        Style::default()
            .fg(self.colors.button_active_text)
            .bg(self.colors.button_active_bg)
            .add_modifier(Modifier::BOLD)
    }

    pub fn button_inactive(&self) -> Style {
        Style::default()
            .fg(self.colors.muted)
            .bg(self.colors.dim)
    }

    pub fn button_danger(&self) -> Style {
        Style::default()
            .fg(Color::White)
            .bg(self.colors.error)
            .add_modifier(Modifier::BOLD)
    }

    // === Header ===
    pub fn header_separator(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    pub fn header_version(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn header_provider(&self) -> Style {
        Style::default().fg(self.colors.secondary)
    }

    pub fn header_model(&self) -> Style {
        Style::default().fg(self.colors.primary)
    }

    // === Input ===
    pub fn input_placeholder(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    pub fn input_cursor(&self) -> Style {
        Style::default().fg(self.colors.primary)
    }

    // === Scrollbar ===
    pub fn scrollbar_thumb(&self) -> Style {
        Style::default().fg(self.colors.primary)
    }

    pub fn scrollbar_track(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    // === Selection ===
    pub fn text_selection(&self) -> Style {
        Style::default()
            .fg(Color::White)
            .bg(self.colors.selection_bg)
    }

    // === Radio ===
    pub fn radio_on(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn radio_off(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    // === Help ===
    pub fn help_key(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .add_modifier(Modifier::BOLD)
    }

    pub fn help_desc(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    pub fn help_separator(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    // === Progress ===
    pub fn progress_filled(&self) -> Style {
        Style::default().fg(self.colors.primary)
    }

    pub fn progress_empty(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    pub fn progress_label(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    // === Attachment ===
    pub fn attachment_chip(&self) -> Style {
        Style::default()
            .fg(self.colors.secondary)
            .bg(self.colors.dim)
    }

    pub fn attachment_delete(&self) -> Style {
        Style::default().fg(self.colors.error)
    }

    // === Section ===
    pub fn section_title(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    // === GFM tables ===

    /// The box-drawing grid of a rendered markdown table (outer frame, the
    /// vertical rules between columns, and the horizontal rule under every
    /// row). Uses the theme's neutral `border` so the grid reads as thin
    /// light-grey chrome in every theme and in both light and dark modes —
    /// never a hardcoded colour.
    pub fn table_rule(&self) -> Style {
        Style::default().fg(self.colors.border)
    }

    /// The header row of a markdown table: the theme accent, bold, so the
    /// first row is visually distinct from the data rows.
    pub fn table_header(&self) -> Style {
        Style::default()
            .fg(self.colors.primary)
            .add_modifier(Modifier::BOLD)
    }

    /// The centred `▼` drawn under a table whose content the renderer had to
    /// cut short — the "there is more below" affordance.
    pub fn table_overflow(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    // === Claude-Code-style chrome (input box, status line, ctx hint) ===

    /// Full-width `─` rule framing the input box (top & bottom dividers).
    /// Claude's `promptBorder` medium gray, not the faint header rule.
    pub fn prompt_border(&self) -> Style {
        Style::default().fg(self.colors.border)
    }

    /// Right-aligned "N% context used" hint above the input box.
    pub fn ctx_hint(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    /// Filled cells of the braille context-usage bar.
    pub fn ctx_bar_fill(&self) -> Style {
        Style::default().fg(self.colors.primary)
    }

    /// Empty (`░`) cells of the braille context-usage bar.
    pub fn ctx_bar_empty(&self) -> Style {
        Style::default().fg(self.colors.muted)
    }

    /// Separators in the status line: `" │ "` and `" · "`.
    pub fn status_sep(&self) -> Style {
        Style::default().fg(self.colors.dim)
    }

    /// Leading spinner glyph + decorative accent glyphs in the status line.
    pub fn status_glyph(&self) -> Style {
        Style::default().fg(self.colors.secondary)
    }

    /// Context bar color based on utilization severity
    pub fn context_bar_color(&self, utilization: f64) -> Color {
        if utilization >= 0.90 {
            self.colors.error
        } else if utilization >= 0.75 {
            self.colors.warning
        } else {
            self.colors.primary
        }
    }

    /// Render a context bar with filled/empty segments and severity coloring
    pub fn render_context_bar(&self, utilization: f64, width: u16) -> (String, Style) {
        let filled = (utilization * width as f64).floor() as u16;
        let empty = width.saturating_sub(filled);
        let bar = format!(
            "{}{}",
            "\u{2588}".repeat(filled as usize),
            "\u{2591}".repeat(empty as usize)
        );
        let color = self.context_bar_color(utilization);
        (bar, Style::default().fg(color))
    }
}

// Global theme access
use std::sync::RwLock;

static CURRENT_THEME: RwLock<Option<Theme>> = RwLock::new(None);

pub fn set_theme(theme: Theme) {
    // Recover from a poisoned lock rather than propagating a panic.
    *CURRENT_THEME.write().unwrap_or_else(|e| e.into_inner()) = Some(theme);
}

pub fn theme() -> Theme {
    CURRENT_THEME
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_else(|| themes::dark())
}
