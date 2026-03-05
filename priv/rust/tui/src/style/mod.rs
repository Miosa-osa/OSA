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

    pub fn agent_role(&self) -> Style {
        Style::default().fg(self.colors.muted)
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
