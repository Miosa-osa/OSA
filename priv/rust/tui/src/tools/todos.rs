use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

use super::{make_header, render_tool_box, truncate_lines, RenderOpts, ToolRenderer};

pub struct TodosRenderer;

impl ToolRenderer for TodosRenderer {
    fn render(
        &self,
        _name: &str,
        _args: &str,
        result: &str,
        opts: &RenderOpts,
    ) -> Vec<Line<'static>> {
        let theme = crate::style::theme();

        let todos = parse_todos(result);

        let completed = todos
            .iter()
            .filter(|t| t.status == TodoStatus::Completed)
            .count();
        let total = todos.len();

        let detail = if total > 0 {
            format!("{}/{} complete", completed, total)
        } else {
            String::new()
        };

        let header = make_header(
            opts.status,
            opts.spinner_frame,
            "Todos",
            &detail,
            opts.duration_ms,
        );

        if !opts.expanded {
            return vec![header];
        }

        let mut body: Vec<Line<'static>> = Vec::new();

        if todos.is_empty() {
            // Plain fallback
            for line in result.lines() {
                body.push(Line::from(Span::styled(line.to_string(), theme.faint())));
            }
        } else {
            for todo in &todos {
                let (icon, icon_style) = todo_icon(&todo.status, &theme);
                let content_style = match todo.status {
                    TodoStatus::Completed => Style::default().fg(theme.colors.muted),
                    TodoStatus::Failed => Style::default().fg(theme.colors.error),
                    TodoStatus::InProgress => Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                    TodoStatus::Pending => Style::default().fg(theme.colors.muted),
                };

                body.push(Line::from(vec![
                    Span::styled(icon, icon_style),
                    Span::raw(" "),
                    Span::styled(todo.content.clone(), content_style),
                ]));
            }

            // Footer summary
            body.push(Line::from(Span::styled(
                format!("{}/{} complete", completed, total),
                Style::default().fg(theme.colors.dim),
            )));
        }

        let max_lines = if opts.compact { 8 } else { 20 };
        let body = truncate_lines(body, max_lines);

        render_tool_box(header, body)
    }
}

// ─── Todo Entry ───────────────────────────────────────────────────────────────

#[derive(Debug, PartialEq)]
enum TodoStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
}

#[derive(Debug)]
struct TodoEntry {
    content: String,
    status: TodoStatus,
}

fn parse_todos(result: &str) -> Vec<TodoEntry> {
    // Try JSON array
    let v: serde_json::Value = match serde_json::from_str(result) {
        Ok(v) => v,
        Err(_) => return parse_plain_todos(result),
    };

    let arr = match v.as_array() {
        Some(a) => a,
        None => {
            // Might be wrapped: { "todos": [...] }
            if let Some(inner) = v.get("todos").and_then(|t| t.as_array()) {
                return inner.iter().filter_map(parse_todo_item).collect();
            }
            return parse_plain_todos(result);
        }
    };

    arr.iter().filter_map(parse_todo_item).collect()
}

fn parse_todo_item(item: &serde_json::Value) -> Option<TodoEntry> {
    let content = item
        .get("content")
        .or_else(|| item.get("text"))
        .or_else(|| item.get("description"))
        .or_else(|| item.get("task"))
        .and_then(|s| s.as_str())?
        .to_string();

    let status_str = item
        .get("status")
        .or_else(|| item.get("state"))
        .and_then(|s| s.as_str())
        .unwrap_or("pending")
        .to_lowercase();

    let status = match status_str.as_str() {
        "completed" | "done" | "complete" | "finished" => TodoStatus::Completed,
        "in_progress" | "inprogress" | "active" | "running" => TodoStatus::InProgress,
        "failed" | "error" => TodoStatus::Failed,
        _ => TodoStatus::Pending,
    };

    Some(TodoEntry { content, status })
}

/// Parse markdown-style todo list from plain text:
/// `- [ ] pending`, `- [x] done`, `- [>] in_progress`
fn parse_plain_todos(text: &str) -> Vec<TodoEntry> {
    let mut entries = Vec::new();
    for line in text.lines() {
        let t = line.trim();
        let (status, content) = if t.starts_with("- [x]") || t.starts_with("- [X]") {
            (TodoStatus::Completed, t[5..].trim().to_string())
        } else if t.starts_with("- [>]") {
            (TodoStatus::InProgress, t[5..].trim().to_string())
        } else if t.starts_with("- [!]") {
            (TodoStatus::Failed, t[5..].trim().to_string())
        } else if t.starts_with("- [ ]") {
            (TodoStatus::Pending, t[5..].trim().to_string())
        } else if t.starts_with("- ") || t.starts_with("* ") {
            (TodoStatus::Pending, t[2..].trim().to_string())
        } else {
            continue;
        };
        if !content.is_empty() {
            entries.push(TodoEntry { content, status });
        }
    }
    entries
}

fn todo_icon(status: &TodoStatus, theme: &crate::style::Theme) -> (String, Style) {
    match status {
        TodoStatus::InProgress => (
            "◼".to_string(),
            Style::default()
                .fg(theme.colors.primary)
                .add_modifier(Modifier::BOLD),
        ),
        TodoStatus::Pending => ("◻".to_string(), Style::default().fg(theme.colors.muted)),
        TodoStatus::Completed => (
            "✔".to_string(),
            Style::default()
                .fg(theme.colors.success)
                .add_modifier(Modifier::BOLD),
        ),
        TodoStatus::Failed => (
            "✘".to_string(),
            Style::default()
                .fg(theme.colors.error)
                .add_modifier(Modifier::BOLD),
        ),
    }
}
