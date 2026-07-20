use ratatui::text::Line;

use super::{
    make_header, render_tool_box, truncate_lines, RenderOpts, ToolRenderer, ToolStatus,
};

/// Fallback renderer for all unregistered tools.
pub struct GenericRenderer;

impl ToolRenderer for GenericRenderer {
    fn render(&self, name: &str, args: &str, result: &str, opts: &RenderOpts) -> Vec<Line<'static>> {
        // Use the raw tool name as display, collapse args into a short preview
        let args_preview = args_summary(args);

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            name,
            &args_preview,
            opts.duration_ms,
        );

        let is_error = opts.status == ToolStatus::Error;

        if !opts.expanded {
            // CC parity: unknown tools still show a short dimmed result block
            // under a `⎿` connector — 3 width-wrapped lines max plus a ctrl+o
            // hint (OutputLine) — now with JSON pretty-print, URL linkify, and
            // the panel background shared by every tool renderer.
            let body = super::collapse::enhanced_collapsed_block(result, opts.width, is_error);
            if body.is_empty() {
                return vec![header];
            }
            return render_tool_box(header, body);
        }

        // Expanded body: same quality upgrades (JSON pretty-print + URL linkify
        // + panel bg), width-wrapped, then compact-capped.
        let body = super::collapse::enhanced_output_lines(result, opts.width, is_error);
        let max_lines = if opts.compact { 6 } else { 10 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

/// Build a short summary of the args for display in the header.
fn args_summary(args: &str) -> String {
    let trimmed = args.trim();
    if trimmed.is_empty() || trimmed == "{}" {
        return String::new();
    }

    // Try to extract the first string value from JSON
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(trimmed) {
        if let Some(obj) = v.as_object() {
            for val in obj.values() {
                if let Some(s) = val.as_str() {
                    let preview: String = s.chars().take(50).collect();
                    return if s.len() > 50 {
                        format!("{}…", preview)
                    } else {
                        preview
                    };
                }
            }
        }
        // Compact JSON as fallback
        let compact = v.to_string();
        return if compact.len() > 60 {
            format!("{}\u{2026}", crate::util::truncate_str(&compact, 60))
        } else {
            compact
        };
    }

    // Plain string args
    let preview: String = trimmed.chars().take(60).collect();
    if trimmed.len() > 60 {
        format!("{}…", preview)
    } else {
        preview
    }
}
