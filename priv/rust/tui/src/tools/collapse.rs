// Collapsed tool summaries — mirrors Claude Code's collapseReadSearch.ts /
// groupToolUses.ts. A run of consecutive same-KIND tool calls collapses to a
// single scrollback line: "Ran N shell commands", "Read N files",
// "Listed N directories", "Searched for N patterns", "Queried <server>".
//
// There is NO minimum count — even a single read collapses to "Read 1 file".
// Non-collapsible tools (edit/write/etc.) bypass this entirely and keep their
// full per-call rendering.
#![allow(dead_code)]

use std::collections::HashSet;

use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

/// Classification of a finished tool call for collapse grouping.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolKind {
    Search,
    Read,
    List,
    Shell,
    Mcp(String),
    NonCollapsible,
}

impl ToolKind {
    pub fn is_collapsible(&self) -> bool {
        !matches!(self, ToolKind::NonCollapsible)
    }

    /// Bucket key — two kinds with the same key merge into one summary.
    fn family_key(&self) -> Option<String> {
        match self {
            ToolKind::Search => Some("search".to_string()),
            ToolKind::Read => Some("read".to_string()),
            ToolKind::List => Some("list".to_string()),
            ToolKind::Shell => Some("shell".to_string()),
            ToolKind::Mcp(server) => Some(format!("mcp:{}", server)),
            ToolKind::NonCollapsible => None,
        }
    }
}

/// Classify a finished tool call by name (+ args) into a collapse kind.
pub fn classify(name: &str, _args: &str) -> ToolKind {
    let lower = name.to_lowercase();

    // MCP tools: mcp__server__tool → group by server.
    if lower.starts_with("mcp__") {
        let server = lower.split("__").nth(1).unwrap_or("mcp").to_string();
        return ToolKind::Mcp(server);
    }

    match lower.as_str() {
        // Shell — inline viewport treats shell as always collapsible.
        "bash" | "run_bash_command" | "shell" => ToolKind::Shell,
        // Read-family.
        "read" | "read_file" | "file_read" | "cat" | "head" | "tail" => ToolKind::Read,
        // Directory listing.
        "ls" | "list_directory" | "dir_list" | "list_dir" | "tree" | "du" => ToolKind::List,
        // Search / pattern matching.
        "grep" | "file_grep" | "glob" | "file_glob" | "rg" | "search" => ToolKind::Search,
        // Everything else (edit/write/web/task/…) renders in full.
        _ => ToolKind::NonCollapsible,
    }
}

fn extract_read_path(args: &str) -> Option<String> {
    super::parse_json_arg(args, &["file_path", "path", "filename", "file"])
}

fn plural(n: usize) -> &'static str {
    if n == 1 {
        ""
    } else {
        "s"
    }
}

/// Accumulates a run of consecutive same-kind collapsible tools.
#[derive(Default)]
pub struct Accumulator {
    family: Option<String>,
    search_count: usize,
    read_paths: HashSet<String>,
    read_ops: usize,
    list_count: usize,
    shell_count: usize,
    mcp_server: Option<String>,
    mcp_count: usize,
    any_error: bool,
}

impl Accumulator {
    pub fn is_empty(&self) -> bool {
        self.family.is_none()
    }

    /// True if `kind` belongs to the currently-accumulating bucket.
    pub fn family_matches(&self, kind: &ToolKind) -> bool {
        self.family.as_deref() == kind.family_key().as_deref()
    }

    /// Fold one finished collapsible tool into the run.
    pub fn add(&mut self, kind: &ToolKind, args: &str, success: bool) {
        self.family = kind.family_key();
        if !success {
            self.any_error = true;
        }
        match kind {
            ToolKind::Read => {
                if let Some(p) = extract_read_path(args) {
                    self.read_paths.insert(p);
                } else {
                    self.read_ops += 1;
                }
            }
            ToolKind::List => self.list_count += 1,
            ToolKind::Shell => self.shell_count += 1,
            ToolKind::Search => self.search_count += 1,
            ToolKind::Mcp(server) => {
                self.mcp_server = Some(server.clone());
                self.mcp_count += 1;
            }
            ToolKind::NonCollapsible => {}
        }
    }

    fn summary_text(&self) -> String {
        if self.shell_count > 0 {
            let n = self.shell_count;
            format!("Ran {} shell command{}", n, plural(n))
        } else if !self.read_paths.is_empty() || self.read_ops > 0 {
            let n = self.read_paths.len().max(self.read_ops);
            format!("Read {} file{}", n, plural(n))
        } else if self.list_count > 0 {
            let n = self.list_count;
            let noun = if n == 1 { "directory" } else { "directories" };
            format!("Listed {} {}", n, noun)
        } else if self.search_count > 0 {
            let n = self.search_count;
            format!("Searched for {} pattern{}", n, plural(n))
        } else if self.mcp_count > 0 {
            let server = self.mcp_server.clone().unwrap_or_default();
            if self.mcp_count == 1 {
                format!("Queried {}", server)
            } else {
                format!("Queried {} {} times", server, self.mcp_count)
            }
        } else {
            String::new()
        }
    }

    /// Emit the run as a single styled scrollback line and reset. Returns None
    /// when the accumulator is empty.
    pub fn take_summary_line(&mut self) -> Option<Line<'static>> {
        if self.is_empty() {
            return None;
        }
        let text = self.summary_text();
        let err = self.any_error;
        *self = Accumulator::default();
        if text.is_empty() {
            return None;
        }
        let theme = crate::style::theme();
        let icon_color = if err {
            theme.colors.error
        } else {
            theme.colors.success
        };
        Some(Line::from(vec![
            Span::styled(
                format!("{} ", crate::tools::tool_bullet()), // ● (Linux) / ⏺ (macOS)
                Style::default().fg(icon_color).add_modifier(Modifier::BOLD),
            ),
            Span::styled(text, Style::default().fg(theme.colors.muted)),
        ]))
    }
}
