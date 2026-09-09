const COMPACT_MODE_BREAKPOINT: u16 = 100;
const SIDEBAR_MIN_WIDTH: u16 = 28;
const SIDEBAR_MAX_WIDTH: u16 = 40;
const MIN_SIDEBAR_TOTAL_WIDTH: u16 = 79; // SIDEBAR_MIN_WIDTH(28) + chat(50) + border(1)
const HEADER_HEIGHT: u16 = 0; // header hidden — info in welcome msg + status bar
const INPUT_HEIGHT: u16 = 2; // separator + prompt line
const MIN_CHAT_HEIGHT: u16 = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayoutMode {
    Compact,
    Sidebar,
}

// Phase 2: metadata fields (mode, term dims, sidebar_height, compact_mode) exposed for future
// responsive layout decisions and debug overlay — not yet read by render code
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct Layout {
    pub mode: LayoutMode,
    pub term_width: u16,
    pub term_height: u16,
    pub header_height: u16,
    pub status_height: u16,
    pub input_height: u16,
    pub chat_width: u16,
    pub chat_height: u16,
    pub sidebar_width: u16,
    pub sidebar_height: u16,
    pub compact_mode: bool,
}

impl Layout {
    pub fn compute(
        term_width: u16,
        term_height: u16,
        sidebar_enabled: bool,
        task_lines: u16,
        agent_lines: u16,
    ) -> Self {
        Self::compute_with_input_height(
            term_width,
            term_height,
            sidebar_enabled,
            task_lines,
            agent_lines,
            INPUT_HEIGHT,
        )
    }

    pub fn compute_with_input_height(
        term_width: u16,
        term_height: u16,
        sidebar_enabled: bool,
        task_lines: u16,
        agent_lines: u16,
        input_h: u16,
    ) -> Self {
        let compact_mode = term_width < COMPACT_MODE_BREAKPOINT;
        let show_sidebar =
            sidebar_enabled && !compact_mode && term_width >= MIN_SIDEBAR_TOTAL_WIDTH;

        let mode = if show_sidebar {
            LayoutMode::Sidebar
        } else {
            LayoutMode::Compact
        };

        let status_height: u16 = 1;

        let (sidebar_width, chat_width) = if show_sidebar {
            let sw = (term_width / 5).clamp(SIDEBAR_MIN_WIDTH, SIDEBAR_MAX_WIDTH);
            let cw = term_width.saturating_sub(sw).saturating_sub(1); // 1 for border
            (sw, cw)
        } else {
            (0, term_width)
        };

        let used_height = HEADER_HEIGHT + status_height + input_h + task_lines + agent_lines;
        let chat_height = term_height.saturating_sub(used_height).max(MIN_CHAT_HEIGHT);
        let sidebar_height = if show_sidebar { chat_height } else { 0 };

        Self {
            mode,
            term_width,
            term_height,
            header_height: HEADER_HEIGHT,
            status_height,
            input_height: input_h,
            chat_width,
            chat_height,
            sidebar_width,
            sidebar_height,
            compact_mode,
        }
    }
}
