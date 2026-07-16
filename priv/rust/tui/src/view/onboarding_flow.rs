/// Full-screen conversational onboarding renderer.
///
/// Renders the `OnboardingWizard` state as an inline clack-style flow:
/// completed steps scroll up (dimmed, showing their answer), the active
/// step sits at the bottom with its interactive element live.
use ratatui::{
    prelude::*,
    widgets::{Clear, Paragraph},
};

use crate::dialogs::onboarding::OnboardingWizard;

// ── Symbols ───────────────────────────────────────────────────────────────────

const SYM_DIAMOND: &str = "\u{25c6}";   // ◆  header / title
const SYM_OPEN: &str = "\u{25c7}";      // ◇  step prompt
const SYM_PIPE: &str = "\u{2502}";      // │  connector between steps
const SYM_RADIO_ON: &str = "\u{25cf}";  // ●  selected radio
const SYM_RADIO_OFF: &str = "\u{25cb}"; // ○  unselected radio
const SYM_CHECK_ON: &str = "\u{25a0}";  // ■  checked checkbox
const SYM_CHECK_OFF: &str = "\u{25a1}"; // □  unchecked checkbox
const SYM_DONE: &str = "\u{2713}";      // ✓  completed step answer
const SYM_CURSOR: &str = "\u{258c}";    // ▌  text-input cursor bar
const SYM_BULLET: &str = "\u{2022}";    // •  masked char

/// ANSI Shadow figlet "OSA" wordmark — shared with the welcome banner so the
/// first-run flow and the returning-user screen read as the same brand.
const OSA_LOGO: &[&str] = &[
    " \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} \u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557} ",
    "\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2557}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2557}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}",
    "\u{2588}\u{2588}\u{2551}   \u{2588}\u{2588}\u{2551}\u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2554}\u{2550}\u{2550}\u{2588}\u{2588}\u{2551}",
    "\u{255a}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2554}\u{255d}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2551}\u{2588}\u{2588}\u{2551}  \u{2588}\u{2588}\u{2551}",
    " \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d} \u{255a}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{255d}\u{255a}\u{2550}\u{255d}  \u{255a}\u{2550}\u{255d}",
];

/// Push a single line, horizontally centred within `col_w`.
fn push_centered(lines: &mut Vec<Line<'static>>, col_w: u16, text: &str, style: Style) {
    let pad = (col_w as usize).saturating_sub(text.chars().count()) / 2;
    lines.push(Line::from(vec![
        Span::raw(" ".repeat(pad)),
        Span::styled(text.to_string(), style),
    ]));
}

/// Render a gradient (grad_a -> grad_b) string centred within `col_w`.
fn push_centered_gradient(lines: &mut Vec<Line<'static>>, col_w: u16, text: &str) {
    let pad = (col_w as usize).saturating_sub(text.chars().count()) / 2;
    let grad = crate::style::gradient::theme_gradient(text, true);
    let mut spans: Vec<Span<'static>> = Vec::with_capacity(grad.spans.len() + 1);
    spans.push(Span::raw(" ".repeat(pad)));
    spans.extend(grad.spans);
    lines.push(Line::from(spans));
}

/// Branded first-run header: the OSA figlet wordmark rendered in the theme's
/// blue light->dark gradient, with a compact wordmark fallback on small panes.
/// Purely additive — it never changes the wizard's step flow.
fn push_branded_header(
    lines: &mut Vec<Line<'static>>,
    col_w: u16,
    avail_h: u16,
    theme: &crate::style::Theme,
) {
    lines.push(Line::from(""));

    let logo_w = OSA_LOGO.iter().map(|l| l.chars().count()).max().unwrap_or(41);
    let show_logo = (col_w as usize) >= logo_w && avail_h >= 18;

    if show_logo {
        for art in OSA_LOGO {
            push_centered_gradient(lines, col_w, art);
        }
        lines.push(Line::from(""));
        push_centered(
            lines,
            col_w,
            "Agent \u{00b7} first-run setup",
            Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
        );
    } else {
        // Compact: gradient diamond + wordmark on one line.
        push_centered_gradient(lines, col_w, &format!("{} OSA", SYM_DIAMOND));
        push_centered(
            lines,
            col_w,
            "Agent setup",
            Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
        );
    }

    push_centered(
        lines,
        col_w,
        "Let's get you connected \u{2014} about a minute",
        Style::default().fg(theme.colors.dim),
    );
    lines.push(Line::from(""));
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Draw the full-screen conversational onboarding flow.
///
/// Reads wizard state via the `flow_*` accessors and renders everything as a
/// single `Paragraph` of styled `Line`s, centred horizontally in `area`.
pub fn draw_onboarding_flow(frame: &mut Frame, area: Rect, wizard: &OnboardingWizard) {
    let theme = crate::style::theme();

    frame.render_widget(Clear, area);

    // ── Layout ──────────────────────────────────────────────────────────────
    // Constrain to a comfortable reading width, centred.
    let col_w = 60_u16.min(area.width);
    let col_x = area.x + area.width.saturating_sub(col_w) / 2;

    // Build all lines for the content panel.
    let mut lines: Vec<Line<'static>> = Vec::new();

    // Branded first-run banner: the OSA wordmark in the blue grad_a -> grad_b
    // gradient, with a compact fallback on short/narrow panes. This is the
    // first thing a new user sees, so it leads with our identity.
    push_branded_header(&mut lines, col_w, area.height, &theme);

    let step = wizard.flow_step();
    let providers = wizard.flow_providers();

    // ── Completed steps (0..step) ────────────────────────────────────────────
    for completed in 0..step {
        push_completed_step(&mut lines, completed, wizard, &theme);
    }

    // ── Active step ──────────────────────────────────────────────────────────
    push_active_step(&mut lines, step, wizard, &theme);

    // Help footer
    lines.push(Line::from(""));
    lines.push(build_help_line(step, wizard, &theme));
    lines.push(Line::from(""));

    // ── Render ───────────────────────────────────────────────────────────────
    // Vertically position so content is centred (or flush to top if too tall).
    let content_height = lines.len() as u16;
    let y_start = if content_height < area.height {
        area.y + area.height.saturating_sub(content_height) / 2
    } else {
        area.y
    };
    let render_h = content_height.min(area.height);

    // Trim lines that overflow from the top (scroll oldest completed up).
    let skip = lines.len().saturating_sub(render_h as usize);
    let visible: Vec<Line<'static>> = lines.into_iter().skip(skip).collect();

    let paragraph = Paragraph::new(Text::from(visible));
    let render_area = Rect::new(col_x, y_start, col_w, render_h);
    frame.render_widget(paragraph, render_area);

    // Suppress unused-variable warning for providers (used indirectly via wizard).
    let _ = providers;
}

// ── Completed step renderer ───────────────────────────────────────────────────

fn push_completed_step(
    lines: &mut Vec<Line<'static>>,
    step_idx: usize,
    wizard: &OnboardingWizard,
    theme: &crate::style::Theme,
) {
    let dim = Style::default().fg(theme.colors.dim);
    let done_style = Style::default()
        .fg(theme.colors.success)
        .add_modifier(Modifier::DIM);

    let (prompt, answer) = completed_step_summary(step_idx, wizard);

    // ◇  Prompt label (dimmed)
    lines.push(Line::from(vec![
        Span::styled(format!("  {}  ", SYM_OPEN), dim),
        Span::styled(prompt, dim),
    ]));

    // │  Answer (green-ish, dimmed)
    lines.push(Line::from(vec![
        Span::styled(format!("  {}  ", SYM_PIPE), dim),
        Span::styled(
            format!("{} {}", SYM_DONE, answer),
            done_style,
        ),
    ]));

    lines.push(Line::from(""));
}

/// Returns (prompt_label, answer_summary) for a completed step.
fn completed_step_summary(step_idx: usize, wizard: &OnboardingWizard) -> (String, String) {
    let providers = wizard.flow_providers();

    match step_idx {
        0 => {
            let name = providers
                .get(wizard.flow_selected_provider())
                .map(|p| p.name.as_str())
                .unwrap_or("?")
                .to_string();
            ("How do you want to connect?".to_string(), name)
        }
        1 => {
            let answer = if wizard.flow_provider_needs_key() {
                wizard.flow_api_key_preview()
            } else if wizard.flow_provider_needs_url() {
                let url = wizard.flow_base_url();
                if url.is_empty() {
                    "default endpoint".to_string()
                } else {
                    url.to_string()
                }
            } else {
                "no credentials needed".to_string()
            };
            ("Credentials".to_string(), answer)
        }
        2 => {
            let model_list = wizard.flow_model_list();
            let answer = if model_list.is_empty() {
                let input = wizard.flow_model_input();
                if input.is_empty() {
                    "default".to_string()
                } else {
                    input.to_string()
                }
            } else {
                model_list
                    .get(wizard.flow_selected_model())
                    .map(|(id, _)| id.clone())
                    .unwrap_or_else(|| "default".to_string())
            };
            ("Model".to_string(), answer)
        }
        3 => {
            let (_, is_ok, latency, _) = wizard.flow_verify_state();
            let answer = if is_ok {
                latency
                    .map(|ms| format!("connected ({}ms)", ms))
                    .unwrap_or_else(|| "connected".to_string())
            } else {
                "skipped".to_string()
            };
            ("Connection verified".to_string(), answer)
        }
        4 => {
            let channels = OnboardingWizard::flow_channel_list();
            let tokens = wizard.flow_channel_tokens();
            let selected = wizard.flow_selected_channels();
            let active: Vec<&str> = channels
                .iter()
                .enumerate()
                .filter(|(i, _)| selected.get(*i).copied().unwrap_or(false))
                .map(|(_, (_, name, _))| *name)
                .collect();
            let answer = if active.is_empty() {
                "terminal only".to_string()
            } else {
                let configured: Vec<&str> = channels
                    .iter()
                    .enumerate()
                    .filter(|(i, (id, _, _))| {
                        selected.get(*i).copied().unwrap_or(false)
                            && tokens.contains_key(*id)
                    })
                    .map(|(_, (_, name, _))| *name)
                    .collect();
                if configured.is_empty() {
                    active.join(", ")
                } else {
                    configured.join(", ")
                }
            };
            ("Channels".to_string(), answer)
        }
        _ => ("".to_string(), "".to_string()),
    }
}

// ── Active step renderer ──────────────────────────────────────────────────────

fn push_active_step(
    lines: &mut Vec<Line<'static>>,
    step: usize,
    wizard: &OnboardingWizard,
    theme: &crate::style::Theme,
) {
    let prompt_style = Style::default()
        .fg(Color::White)
        .add_modifier(Modifier::BOLD);
    let active_sym = Style::default()
        .fg(theme.colors.primary)
        .add_modifier(Modifier::BOLD);

    match step {
        0 => push_provider_select(lines, wizard, theme, prompt_style, active_sym),
        1 => push_details_input(lines, wizard, theme, prompt_style, active_sym),
        2 => push_model_select(lines, wizard, theme, prompt_style, active_sym),
        3 => push_verify(lines, wizard, theme, prompt_style, active_sym),
        4 => push_channels(lines, wizard, theme, prompt_style, active_sym),
        5 => push_confirm(lines, wizard, theme, prompt_style, active_sym),
        _ => {}
    }
}

fn push_provider_select(
    lines: &mut Vec<Line<'static>>,
    wizard: &OnboardingWizard,
    theme: &crate::style::Theme,
    prompt_style: Style,
    active_sym: Style,
) {
    lines.push(Line::from(vec![
        Span::styled(format!("  {}  ", SYM_OPEN), active_sym),
        Span::styled("How do you want to connect?", prompt_style),
    ]));
    lines.push(Line::from(""));

    let providers = wizard.flow_providers();
    let selected = wizard.flow_selected_provider();
    let mut last_group: Option<&str> = None;

    for (i, p) in providers.iter().enumerate() {
        let group = p.group.as_str();
        if last_group != Some(group) {
            let label = match group {
                "recommended" => "     \u{2500}\u{2500} Recommended \u{2500}\u{2500}",
                _ => "     \u{2500}\u{2500} Bring Your Own \u{2500}\u{2500}",
            };
            lines.push(Line::from(vec![Span::styled(
                label.to_string(),
                Style::default().fg(theme.colors.dim),
            )]));
            last_group = Some(group);
        }

        let is_sel = selected == i;
        let radio = if is_sel { SYM_RADIO_ON } else { SYM_RADIO_OFF };
        let (radio_style, label_style) = if is_sel {
            (
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            )
        } else {
            (
                Style::default().fg(theme.colors.muted),
                Style::default().fg(theme.colors.muted),
            )
        };

        let desc = if p.description.is_empty() {
            String::new()
        } else {
            format!("  ({})", p.description)
        };

        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled(format!("{}  ", radio), radio_style),
            Span::styled(p.name.clone(), label_style),
            Span::styled(desc, Style::default().fg(theme.colors.dim)),
        ]));
    }

    lines.push(Line::from(""));
}

fn push_details_input(
    lines: &mut Vec<Line<'static>>,
    wizard: &OnboardingWizard,
    theme: &crate::style::Theme,
    prompt_style: Style,
    active_sym: Style,
) {
    let providers = wizard.flow_providers();
    let provider_name = providers
        .get(wizard.flow_selected_provider())
        .map(|p| p.name.as_str())
        .unwrap_or("Provider");

    lines.push(Line::from(vec![
        Span::styled(format!("  {}  ", SYM_OPEN), active_sym),
        Span::styled(format!("{} credentials", provider_name), prompt_style),
    ]));
    lines.push(Line::from(""));

    // Signup URL hint
    if let Some(url) = providers
        .get(wizard.flow_selected_provider())
        .and_then(|p| p.signup_url.as_deref())
    {
        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled(url.to_string(), Style::default().fg(theme.colors.dim)),
        ]));
        lines.push(Line::from(""));
    }

    if wizard.flow_provider_needs_key() {
        let env_label = providers
            .get(wizard.flow_selected_provider())
            .and_then(|p| p.env_var.as_deref())
            .unwrap_or("API_KEY");

        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled(
                format!("{}:", env_label),
                Style::default().fg(theme.colors.muted),
            ),
        ]));

        let display = wizard.flow_api_key_display();
        let masked_indicator = if wizard.flow_api_key_masked() {
            SYM_BULLET.repeat(display.chars().count().max(1))
        } else {
            display.clone()
        };

        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(SYM_CURSOR.to_string(), Style::default().fg(theme.colors.primary)),
            Span::raw(" "),
            Span::styled(
                format!("{}_", masked_indicator),
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));
        lines.push(Line::from(""));
    }

    if wizard.flow_provider_needs_url() {
        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled("Base URL:".to_string(), Style::default().fg(theme.colors.muted)),
        ]));

        let url = wizard.flow_base_url();
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(SYM_CURSOR.to_string(), Style::default().fg(theme.colors.primary)),
            Span::raw(" "),
            Span::styled(
                format!("{}_", url),
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));
        lines.push(Line::from(""));
    }

    if !wizard.flow_provider_needs_key() && !wizard.flow_provider_needs_url() {
        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled(
                "No credentials needed for this provider.",
                Style::default().fg(theme.colors.dim),
            ),
        ]));
        lines.push(Line::from(""));
    }
}

fn push_model_select(
    lines: &mut Vec<Line<'static>>,
    wizard: &OnboardingWizard,
    theme: &crate::style::Theme,
    prompt_style: Style,
    active_sym: Style,
) {
    lines.push(Line::from(vec![
        Span::styled(format!("  {}  ", SYM_OPEN), active_sym),
        Span::styled("Choose a model", prompt_style),
    ]));
    lines.push(Line::from(""));

    let model_list = wizard.flow_model_list();

    if model_list.is_empty() {
        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled("Model name:".to_string(), Style::default().fg(theme.colors.muted)),
        ]));
        let input = wizard.flow_model_input();
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(SYM_CURSOR.to_string(), Style::default().fg(theme.colors.primary)),
            Span::raw(" "),
            Span::styled(
                format!("{}_", input),
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));
    } else {
        let selected = wizard.flow_selected_model();
        for (i, (_id, label)) in model_list.iter().enumerate() {
            let is_sel = selected == i;
            let radio = if is_sel { SYM_RADIO_ON } else { SYM_RADIO_OFF };
            let (radio_style, label_style) = if is_sel {
                (
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                    Style::default()
                        .fg(Color::White)
                        .add_modifier(Modifier::BOLD),
                )
            } else {
                (
                    Style::default().fg(theme.colors.muted),
                    Style::default().fg(theme.colors.muted),
                )
            };

            // Truncate long labels so they don't wrap. Truncate by chars, not
            // bytes: a model name with multi-byte UTF-8 could put byte 49 mid-char.
            let display_label = if label.chars().count() > 50 {
                format!("{}\u{2026}", label.chars().take(49).collect::<String>())
            } else {
                label.clone()
            };

            lines.push(Line::from(vec![
                Span::raw("     "),
                Span::styled(format!("{}  ", radio), radio_style),
                Span::styled(display_label, label_style),
            ]));
        }
    }

    lines.push(Line::from(""));
}

fn push_verify(
    lines: &mut Vec<Line<'static>>,
    wizard: &OnboardingWizard,
    theme: &crate::style::Theme,
    prompt_style: Style,
    active_sym: Style,
) {
    lines.push(Line::from(vec![
        Span::styled(format!("  {}  ", SYM_OPEN), active_sym),
        Span::styled("Verifying connection", prompt_style),
    ]));
    lines.push(Line::from(""));

    let (is_pending, is_ok, latency, error) = wizard.flow_verify_state();

    if is_pending {
        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled(
                "\u{25d0} Testing connection...",
                Style::default().fg(theme.colors.secondary),
            ),
        ]));
    } else if is_ok {
        let ms_label = latency
            .map(|ms| format!(" ({}ms)", ms))
            .unwrap_or_default();
        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled(
                format!("{} Connection verified{}", SYM_DONE, ms_label),
                Style::default()
                    .fg(theme.colors.success)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));
    } else if let Some(msg) = error {
        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled(
                format!("\u{2717} {}", msg),
                Style::default().fg(theme.colors.error),
            ),
        ]));
        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled(
                "Press r to retry",
                Style::default().fg(theme.colors.dim),
            ),
        ]));
    }

    lines.push(Line::from(""));
}

fn push_channels(
    lines: &mut Vec<Line<'static>>,
    wizard: &OnboardingWizard,
    theme: &crate::style::Theme,
    prompt_style: Style,
    active_sym: Style,
) {
    let channel_list = OnboardingWizard::flow_channel_list();
    let instructions_list = OnboardingWizard::flow_channel_instructions();

    if let Some(ch_idx) = wizard.flow_current_channel_setup() {
        // Token input sub-step for a specific channel. Use .get() so a future
        // drift between the channel and instruction arrays can't panic here.
        let ch_name = channel_list.get(ch_idx).map(|(_, n, _)| *n).unwrap_or("Channel");
        let instructions: &[&str] = instructions_list.get(ch_idx).copied().unwrap_or(&[]);

        lines.push(Line::from(vec![
            Span::styled(format!("  {}  ", SYM_OPEN), active_sym),
            Span::styled(format!("{} token", ch_name), prompt_style),
        ]));
        lines.push(Line::from(""));

        for instr in instructions.iter() {
            lines.push(Line::from(vec![
                Span::raw("     "),
                Span::styled(instr.to_string(), Style::default().fg(theme.colors.dim)),
            ]));
        }
        lines.push(Line::from(""));

        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled("Bot token:".to_string(), Style::default().fg(theme.colors.muted)),
        ]));

        let display = wizard.flow_channel_token_display();
        let masked_display = if wizard.flow_channel_token_masked() {
            SYM_BULLET.repeat(display.chars().count().max(1))
        } else {
            display.clone()
        };

        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(SYM_CURSOR.to_string(), Style::default().fg(theme.colors.primary)),
            Span::raw(" "),
            Span::styled(
                format!("{}_", masked_display),
                Style::default()
                    .fg(theme.colors.primary)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));
    } else {
        // Channel selection list
        lines.push(Line::from(vec![
            Span::styled(format!("  {}  ", SYM_OPEN), active_sym),
            Span::styled("Connect channels (optional)", prompt_style),
        ]));
        lines.push(Line::from(vec![
            Span::raw("  "),
            Span::styled(
                format!("{}  ", SYM_PIPE),
                Style::default().fg(theme.colors.dim),
            ),
            Span::styled(
                "OSA can receive messages from other platforms.",
                Style::default().fg(theme.colors.dim),
            ),
        ]));
        lines.push(Line::from(""));

        let selected = wizard.flow_selected_channels();
        let tokens = wizard.flow_channel_tokens();
        // confirm_selected is reused as channel cursor in this step.
        let cursor = wizard.flow_confirm_selected().min(channel_list.len().saturating_sub(1));

        for (i, (id, name, hint)) in channel_list.iter().enumerate() {
            let is_checked = selected.get(i).copied().unwrap_or(false);
            let is_cursor = cursor == i;
            let has_token = tokens.contains_key(*id);

            let check = if is_checked { SYM_CHECK_ON } else { SYM_CHECK_OFF };
            let token_mark = if is_checked && has_token {
                format!("  {}", SYM_DONE)
            } else {
                String::new()
            };

            let (check_style, label_style) = if is_cursor {
                (
                    Style::default()
                        .fg(theme.colors.primary)
                        .add_modifier(Modifier::BOLD),
                    Style::default()
                        .fg(Color::White)
                        .add_modifier(Modifier::BOLD),
                )
            } else if is_checked {
                (
                    Style::default().fg(theme.colors.secondary),
                    Style::default().fg(theme.colors.secondary),
                )
            } else {
                (
                    Style::default().fg(theme.colors.muted),
                    Style::default().fg(theme.colors.muted),
                )
            };

            lines.push(Line::from(vec![
                Span::raw("     "),
                Span::styled(format!("{}  ", check), check_style),
                Span::styled(format!("{:<10}", name), label_style),
                Span::styled(
                    format!("  \u{2014} {}{}", hint, token_mark),
                    Style::default().fg(theme.colors.dim),
                ),
            ]));
        }
    }

    lines.push(Line::from(""));
}

fn push_confirm(
    lines: &mut Vec<Line<'static>>,
    wizard: &OnboardingWizard,
    theme: &crate::style::Theme,
    prompt_style: Style,
    active_sym: Style,
) {
    let providers = wizard.flow_providers();
    let selected_provider = wizard.flow_selected_provider();

    lines.push(Line::from(vec![
        Span::styled(format!("  {}  ", SYM_OPEN), active_sym),
        Span::styled("Ready to go", prompt_style),
    ]));
    lines.push(Line::from(""));

    // Summary grid
    let provider_name = providers
        .get(selected_provider)
        .map(|p| p.name.as_str())
        .unwrap_or("\u{2014}")
        .to_string();

    let model_list = wizard.flow_model_list();
    let model_name = if !model_list.is_empty() {
        model_list
            .get(wizard.flow_selected_model())
            .map(|(id, _)| id.as_str())
            .unwrap_or("\u{2014}")
            .to_string()
    } else {
        let input = wizard.flow_model_input();
        if input.is_empty() {
            providers
                .get(selected_provider)
                .and_then(|p| p.default_model.as_deref())
                .unwrap_or("\u{2014}")
                .to_string()
        } else {
            input.to_string()
        }
    };

    let key_display = wizard.flow_api_key_preview();

    let channel_list = OnboardingWizard::flow_channel_list();
    let ch_selected = wizard.flow_selected_channels();
    let active_channels: Vec<&str> = channel_list
        .iter()
        .enumerate()
        .filter(|(i, _)| ch_selected.get(*i).copied().unwrap_or(false))
        .map(|(_, (_, name, _))| *name)
        .collect();
    let channels_display = if active_channels.is_empty() {
        "terminal only".to_string()
    } else {
        active_channels.join(", ")
    };

    let summary = [
        ("Provider", provider_name),
        ("Model", model_name),
        ("API Key", key_display),
        ("Channels", channels_display),
    ];

    for (label, value) in &summary {
        lines.push(Line::from(vec![
            Span::raw("     "),
            Span::styled(
                format!("{:<10}", label),
                Style::default().fg(theme.colors.muted),
            ),
            Span::styled(value.clone(), Style::default().fg(Color::White)),
        ]));
    }

    lines.push(Line::from(""));

    // Confirm / Back buttons
    let confirm_sel = wizard.flow_confirm_selected();
    let (confirm_style, back_style) = if confirm_sel == 0 {
        (theme.button_active(), theme.button_inactive())
    } else {
        (theme.button_inactive(), theme.button_active())
    };

    lines.push(Line::from(vec![
        Span::raw("     "),
        Span::styled("  Confirm  ".to_string(), confirm_style),
        Span::raw("   "),
        Span::styled("  Back  ".to_string(), back_style),
    ]));

    lines.push(Line::from(""));
}

// ── Help line ─────────────────────────────────────────────────────────────────

fn build_help_line<'a>(
    step: usize,
    wizard: &OnboardingWizard,
    theme: &crate::style::Theme,
) -> Line<'a> {
    let key = |s: &str| -> Span<'a> {
        Span::styled(
            s.to_string(),
            Style::default()
                .fg(theme.colors.secondary)
                .add_modifier(Modifier::BOLD),
        )
    };
    let sep = || -> Span<'a> {
        Span::styled("  ".to_string(), Style::default().fg(theme.colors.dim))
    };
    let desc = |s: &str| -> Span<'a> {
        Span::styled(s.to_string(), Style::default().fg(theme.colors.muted))
    };

    let mut spans: Vec<Span<'a>> = vec![Span::raw("  ")];

    match step {
        0 => {
            spans.extend([
                key("\u{2191}\u{2193}"),
                desc(" navigate"),
                sep(),
                key("Enter"),
                desc(" select"),
                sep(),
                key("Esc"),
                desc(" cancel"),
            ]);
        }
        1 => {
            spans.extend([
                key("Tab"),
                desc(" show/hide"),
                sep(),
                key("Enter"),
                desc(" next"),
                sep(),
                key("Esc"),
                desc(" back"),
            ]);
        }
        2 => {
            spans.extend([
                key("\u{2191}\u{2193}"),
                desc(" navigate"),
                sep(),
                key("Enter"),
                desc(" select"),
                sep(),
                key("Esc"),
                desc(" back"),
            ]);
        }
        3 => {
            let (is_pending, _, _, _) = wizard.flow_verify_state();
            if !is_pending {
                spans.extend([key("Enter"), desc(" next"), sep()]);
            }
            spans.extend([key("r"), desc(" retry"), sep(), key("Esc"), desc(" back")]);
        }
        4 => {
            if wizard.flow_current_channel_setup().is_some() {
                spans.extend([
                    key("Tab"),
                    desc(" show/hide"),
                    sep(),
                    key("Enter"),
                    desc(" next"),
                    sep(),
                    key("Esc"),
                    desc(" back"),
                ]);
            } else {
                spans.extend([
                    key("Space"),
                    desc(" toggle"),
                    sep(),
                    key("Enter"),
                    desc(" next"),
                    sep(),
                    key("Esc"),
                    desc(" skip"),
                ]);
            }
        }
        5 => {
            spans.extend([
                key("\u{2190}\u{2192}/Tab"),
                desc(" focus"),
                sep(),
                key("Enter"),
                desc(" confirm"),
                sep(),
                key("Esc"),
                desc(" back"),
            ]);
        }
        _ => {}
    }

    Line::from(spans)
}

#[cfg(test)]
mod flow_render_tests {
    use super::*;
    use crate::dialogs::onboarding::{OnboardingData, OnboardingWizard};
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;

    // Includes the extreme tiny sizes required by the audit plus a large one.
    const SIZES: &[(u16, u16)] = &[(1, 1), (10, 3), (20, 5), (60, 20), (200, 60)];

    fn enter(wizard: &mut OnboardingWizard) {
        let _ = wizard.handle_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::empty()));
    }

    fn wizard_with(providers: serde_json::Value) -> OnboardingWizard {
        let providers = serde_json::from_value(providers).unwrap();
        OnboardingWizard::new(OnboardingData {
            providers,
            system_info: std::collections::HashMap::new(),
        })
    }

    fn draw_all_sizes(wizard: &OnboardingWizard) {
        for &(w, h) in SIZES {
            let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
            term.draw(|f| {
                let area = f.area();
                draw_onboarding_flow(f, area, wizard);
            })
            .unwrap();
        }
    }

    #[test]
    fn branded_flow_multibyte_model_never_panics() {
        // A model label with a multi-byte name so push_model's label shortening
        // runs on non-ASCII content, plus the branded gradient header.
        let mut wizard = wizard_with(serde_json::json!([{
            "id": "custom",
            "name": "Provider \u{00e9}",
            "requires_key": false,
            "models": [
                { "id": "m1", "name": "\u{20ac}".repeat(60), "ctx": 1000000, "tools": true },
                { "id": "m2", "name": "gpt\u{2011}4o\u{2011}\u{4e2d}\u{6587}", "ctx": 128000 }
            ]
        }]));
        for _ in 0..8 {
            draw_all_sizes(&wizard);
            enter(&mut wizard);
        }
    }

    #[test]
    fn branded_flow_empty_providers_never_panics() {
        let wizard = wizard_with(serde_json::json!([]));
        draw_all_sizes(&wizard);
    }

    #[test]
    fn branded_flow_channel_token_step_never_panics() {
        let mut wizard = wizard_with(serde_json::json!([{
            "id": "custom", "name": "Custom", "requires_key": false,
            "models": [ { "id": "m1", "name": "model-one", "ctx": 1000 } ]
        }]));
        // provider->details->model->verify->channels
        for _ in 0..4 {
            enter(&mut wizard);
        }
        let _ = wizard.handle_key(KeyEvent::new(KeyCode::Char(' '), KeyModifiers::empty()));
        enter(&mut wizard); // open first selected channel's token screen
        draw_all_sizes(&wizard);
    }
}
