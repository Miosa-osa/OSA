use ratatui::style::Color;

use super::{Theme, ThemeColors};

fn hex(s: &str) -> Color {
    let s = s.trim_start_matches('#');
    // All callers pass compile-time hex literals; fallback to 0 avoids a panic
    // if a digit is ever malformed rather than producing a wrong color.
    let r = u8::from_str_radix(s.get(0..2).unwrap_or("00"), 16).unwrap_or(0);
    let g = u8::from_str_radix(s.get(2..4).unwrap_or("00"), 16).unwrap_or(0);
    let b = u8::from_str_radix(s.get(4..6).unwrap_or("00"), 16).unwrap_or(0);
    Color::Rgb(r, g, b)
}

/// Dark theme — OSA's OWN identity: the blue we use. Claude Code's *structure*
/// was adopted (the ● bullet, the input-box rule, the status line, green/red
/// status) but the accent + banner colors stay OSA blue, not Claude orange.
pub fn dark() -> Theme {
    Theme {
        name: "dark".to_string(),
        colors: ThemeColors {
            primary: hex("#06B6D4"),   // OSA blue — accent, spinner, headers, banner
            secondary: hex("#7DD3FC"), // light blue — user, paths, tool names
            success: Color::Rgb(78, 186, 101), // green — success bullet, done
            warning: Color::Rgb(255, 193, 7),  // amber
            error: Color::Rgb(255, 107, 128),  // red — error bullet
            muted: Color::Rgb(153, 153, 153),  // meta, durations
            dim: Color::Rgb(80, 80, 80),       // hints, pending bullet, faint rules
            border: Color::Rgb(120, 120, 120), // input-box rule (neutral gray)
            msg_border_user: hex("#7DD3FC"),
            msg_border_agent: hex("#06B6D4"),
            msg_border_system: Color::Rgb(80, 80, 80),
            msg_border_warning: Color::Rgb(255, 193, 7),
            msg_border_error: Color::Rgb(255, 107, 128),
            sidebar_bg: hex("#1F2937"),
            modal_bg: hex("#111827"),
            tooltip_bg: hex("#1F2937"),
            input_bg: hex("#111827"),
            selection_bg: hex("#1E3A5F"), // subtle blue selection
            dialog_bg: hex("#1F2937"),
            button_active_bg: hex("#06B6D4"),  // OSA blue
            button_active_text: hex("#08131A"),
            grad_a: hex("#7DD3FC"),   // OSA logo gradient: light blue →
            grad_b: hex("#06B6D4"),   // OSA blue
            // Word-level diff colors (line bg + brighter changed-word bg).
            diff_del_bg: Color::Rgb(122, 41, 54),
            diff_add_bg: Color::Rgb(34, 92, 43),
            diff_del_highlight_fg: Color::Rgb(255, 255, 255),
            diff_del_highlight_bg: Color::Rgb(179, 89, 107),
            diff_add_highlight_fg: Color::Rgb(255, 255, 255),
            diff_add_highlight_bg: Color::Rgb(56, 166, 96),
        },
    }
}

pub fn light() -> Theme {
    Theme {
        name: "light".to_string(),
        colors: ThemeColors {
            primary: hex("#6D28D9"),
            secondary: hex("#0891B2"),
            success: hex("#16A34A"),
            warning: hex("#D97706"),
            error: hex("#DC2626"),
            muted: hex("#9CA3AF"),
            dim: hex("#D1D5DB"),
            border: hex("#9CA3AF"),
            msg_border_user: hex("#0891B2"),
            msg_border_agent: hex("#6D28D9"),
            msg_border_system: hex("#D1D5DB"),
            msg_border_warning: hex("#D97706"),
            msg_border_error: hex("#DC2626"),
            sidebar_bg: hex("#F3F4F6"),
            modal_bg: hex("#FFFFFF"),
            tooltip_bg: hex("#F3F4F6"),
            input_bg: hex("#FFFFFF"),
            selection_bg: hex("#C4B5FD"),
            dialog_bg: hex("#F3F4F6"),
            button_active_bg: hex("#6D28D9"),
            button_active_text: hex("#FFFFFF"),
            grad_a: hex("#6D28D9"),
            grad_b: hex("#0891B2"),
            diff_del_bg: Color::Rgb(255, 230, 230),
            diff_add_bg: Color::Rgb(220, 255, 220),
            diff_del_highlight_fg: Color::Rgb(180, 0, 0),
            diff_del_highlight_bg: Color::Rgb(255, 200, 200),
            diff_add_highlight_fg: Color::Rgb(0, 130, 0),
            diff_add_highlight_bg: Color::Rgb(180, 255, 180),
        },
    }
}

pub fn catppuccin() -> Theme {
    Theme {
        name: "catppuccin".to_string(),
        colors: ThemeColors {
            primary: hex("#CBA6F7"),
            secondary: hex("#89DCEB"),
            success: hex("#A6E3A1"),
            warning: hex("#F9E2AF"),
            error: hex("#F38BA8"),
            muted: hex("#6C7086"),
            dim: hex("#45475A"),
            border: hex("#6C7086"),
            msg_border_user: hex("#89DCEB"),
            msg_border_agent: hex("#CBA6F7"),
            msg_border_system: hex("#45475A"),
            msg_border_warning: hex("#F9E2AF"),
            msg_border_error: hex("#F38BA8"),
            sidebar_bg: hex("#1E1E2E"),
            modal_bg: hex("#181825"),
            tooltip_bg: hex("#1E1E2E"),
            input_bg: hex("#181825"),
            selection_bg: hex("#45475A"),
            dialog_bg: hex("#1E1E2E"),
            button_active_bg: hex("#CBA6F7"),
            button_active_text: hex("#1E1E2E"),
            grad_a: hex("#CBA6F7"),
            grad_b: hex("#89DCEB"),
            diff_del_bg: Color::Rgb(60, 15, 20),
            diff_add_bg: Color::Rgb(15, 45, 25),
            diff_del_highlight_fg: Color::Rgb(243, 139, 168),
            diff_del_highlight_bg: Color::Rgb(90, 25, 35),
            diff_add_highlight_fg: Color::Rgb(166, 227, 161),
            diff_add_highlight_bg: Color::Rgb(25, 75, 35),
        },
    }
}

pub fn tokyo_night() -> Theme {
    Theme {
        name: "tokyo-night".to_string(),
        colors: ThemeColors {
            primary: hex("#7AA2F7"),
            secondary: hex("#7DCFFF"),
            success: hex("#9ECE6A"),
            warning: hex("#E0AF68"),
            error: hex("#F7768E"),
            muted: hex("#565F89"),
            dim: hex("#3B4261"),
            border: hex("#565F89"),
            msg_border_user: hex("#7DCFFF"),
            msg_border_agent: hex("#7AA2F7"),
            msg_border_system: hex("#3B4261"),
            msg_border_warning: hex("#E0AF68"),
            msg_border_error: hex("#F7768E"),
            sidebar_bg: hex("#1A1B26"),
            modal_bg: hex("#16161E"),
            tooltip_bg: hex("#1A1B26"),
            input_bg: hex("#16161E"),
            selection_bg: hex("#283457"),
            dialog_bg: hex("#1A1B26"),
            button_active_bg: hex("#7AA2F7"),
            button_active_text: hex("#1A1B26"),
            grad_a: hex("#7AA2F7"),
            grad_b: hex("#7DCFFF"),
            diff_del_bg: Color::Rgb(50, 15, 25),
            diff_add_bg: Color::Rgb(15, 40, 20),
            diff_del_highlight_fg: Color::Rgb(247, 118, 142),
            diff_del_highlight_bg: Color::Rgb(80, 25, 35),
            diff_add_highlight_fg: Color::Rgb(158, 206, 106),
            diff_add_highlight_bg: Color::Rgb(25, 70, 30),
        },
    }
}

/// Get theme by name
pub fn by_name(name: &str) -> Option<Theme> {
    match name {
        "dark" => Some(dark()),
        "light" => Some(light()),
        "catppuccin" => Some(catppuccin()),
        "tokyo-night" => Some(tokyo_night()),
        _ => None,
    }
}

/// List all available theme names
pub fn available() -> Vec<&'static str> {
    vec!["dark", "light", "catppuccin", "tokyo-night"]
}
