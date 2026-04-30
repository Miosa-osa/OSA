use ratatui::prelude::*;

use crate::app::layout::Layout;

/// Computed sub-areas from the layout for the main screen
#[allow(dead_code)]
pub struct LayoutAreas {
    pub header: Rect,
    pub chat: Rect,
    pub sidebar: Option<Rect>,
    pub tasks: Option<Rect>,
    pub agents: Option<Rect>,
    /// Dedicated area for the activity spinner (below agents, above status).
    /// None when activity is inactive (height == 0).
    pub activity: Option<Rect>,
    pub status: Rect,
    pub input: Rect,
    pub toast: Rect,
}

impl LayoutAreas {
    #[allow(dead_code)]
    pub fn compute(
        area: Rect,
        layout: &Layout,
        task_lines: u16,
        agent_lines: u16,
        activity_lines: u16,
    ) -> Self {
        Self::compute_with_chat_height(area, layout, task_lines, agent_lines, activity_lines, None)
    }

    /// Compute layout, optionally shrinking the chat area when content is short.
    /// When `chat_content_height` is Some and smaller than available space,
    /// the status bar and input move up to sit right below the chat content
    /// (like the upstream agent CLI — no empty gap between messages and input).
    pub fn compute_with_chat_height(
        area: Rect,
        layout: &Layout,
        task_lines: u16,
        agent_lines: u16,
        activity_lines: u16,
        chat_content_height: Option<u16>,
    ) -> Self {
        let mut y = area.y;
        let area_bottom = area.y.saturating_add(area.height);

        // Header. It is usually hidden, but keep the allocator defensive for
        // tiny terminal sizes.
        let header_height = layout.header_height.min(area.height);
        let header = Rect::new(area.x, y, area.width, header_height);
        y = y.saturating_add(header_height);

        let remaining_after_header = area_bottom.saturating_sub(y);
        let status_height = layout.status_height.min(remaining_after_header);
        let input_height = layout
            .input_height
            .min(remaining_after_header.saturating_sub(status_height));
        let fixed_bottom_height = status_height.saturating_add(input_height);

        // Reserve status/input first so the prompt never gets pushed outside
        // the terminal. Optional panels are then clamped to the space left
        // after a small chat viewport.
        let min_chat_height = 5.min(remaining_after_header.saturating_sub(fixed_bottom_height));
        let mut optional_budget =
            remaining_after_header.saturating_sub(fixed_bottom_height + min_chat_height);

        let task_height = task_lines.min(optional_budget);
        optional_budget = optional_budget.saturating_sub(task_height);

        let agent_height = agent_lines.min(optional_budget);
        optional_budget = optional_budget.saturating_sub(agent_height);

        let activity_height = activity_lines.min(optional_budget);

        let max_chat_height = remaining_after_header
            .saturating_sub(fixed_bottom_height)
            .saturating_sub(task_height)
            .saturating_sub(agent_height)
            .saturating_sub(activity_height);

        // If chat content is shorter than available space, shrink the chat area
        // so the input sits right below the messages (minimal gap).
        let main_height = match chat_content_height {
            Some(content_h) if content_h + 1 < max_chat_height => {
                (content_h + 1).max(4).min(max_chat_height)
            }
            _ => max_chat_height,
        };

        let (sidebar, chat) = if layout.sidebar_width > 0 {
            let sb = Rect::new(area.x, y, layout.sidebar_width, main_height);
            let ch = Rect::new(
                area.x + layout.sidebar_width,
                y,
                layout.chat_width,
                main_height,
            );
            (Some(sb), ch)
        } else {
            let ch = Rect::new(area.x, y, layout.chat_width, main_height);
            (None, ch)
        };
        y += main_height;

        // Tasks
        let tasks = if task_height > 0 {
            let r = Rect::new(area.x, y, area.width, task_height);
            y = y.saturating_add(task_height);
            Some(r)
        } else {
            None
        };

        // Agents
        let agents = if agent_height > 0 {
            let r = Rect::new(area.x, y, area.width, agent_height);
            y = y.saturating_add(agent_height);
            Some(r)
        } else {
            None
        };

        // Activity spinner — dedicated rows below agents, above status bar
        let activity = if activity_height > 0 {
            let r = Rect::new(area.x, y, area.width, activity_height);
            y = y.saturating_add(activity_height);
            Some(r)
        } else {
            None
        };

        // Status bar
        let status = Rect::new(area.x, y, area.width, status_height);
        y = y.saturating_add(status_height);

        // Input (separator + prompt) — pinned height, no excess
        let input = Rect::new(area.x, y, area.width, input_height);

        // Toast overlay (top-right corner)
        let toast = Rect::new(
            area.x + area.width.saturating_sub(40),
            area.y + 1,
            40.min(area.width),
            3,
        );

        Self {
            header,
            chat,
            sidebar,
            tasks,
            agents,
            activity,
            status,
            input,
            toast,
        }
    }
}
