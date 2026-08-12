//! Streaming render-cost measurement (test-only).
//!
//! The smoothness work on the streaming path is only allowed to change things
//! it has measured. This module is the ruler: it drives the SAME calls a real
//! streaming frame makes — `Chat::update_streaming` (the delta), then a
//! `Terminal::draw` that runs `streaming_height` + `draw_live` — once per
//! delta, and reports the per-delta cost.
//!
//! It is a `#[test]`, not a criterion bench, so it runs in the normal
//! `cargo test --release` gate and needs no extra dev-dependency. The numeric
//! assertions are deliberately loose (they exist to catch an order-of-magnitude
//! regression, not to pin a machine-specific number); run with
//! `cargo test --release stream_render_cost -- --nocapture` to read the table.

#![cfg(test)]

use std::time::{Duration, Instant};

use ratatui::{backend::TestBackend, layout::Rect, Terminal};

use crate::components::chat::Chat;

const W: u16 = 100;
const H: u16 = 24;

/// One measured scenario.
struct Sample {
    name: &'static str,
    deltas: usize,
    total: Duration,
}

impl Sample {
    fn per_delta_us(&self) -> f64 {
        self.total.as_secs_f64() * 1e6 / self.deltas as f64
    }
}

/// Stream `text` in `chunk` byte-sized deltas, doing exactly what the event
/// loop does per delta: push the delta, then draw one frame.
fn measure(name: &'static str, text: &str, chunk: usize) -> Sample {
    let mut terminal = Terminal::new(TestBackend::new(W, H)).unwrap();
    let mut chat = Chat::new();
    let area = Rect::new(0, 0, W, H);

    // Warm the syntax/theme lazies so the first delta isn't charged for them.
    {
        let mut warm = Chat::new();
        warm.update_streaming("```rust\nfn main() {}\n```\n");
        let _ = warm.streaming_height(W);
    }

    let mut buf = String::new();
    let mut deltas = 0usize;
    let start = Instant::now();
    for piece in split_chunks(text, chunk) {
        buf.push_str(piece);
        chat.update_streaming(&buf);
        // `streaming_height` is what `measure_bands` calls; `draw_live` is the
        // paint. Both go through the one-parse-per-frame cache, exactly as in
        // `draw_inline`.
        let _ = chat.streaming_height(W);
        terminal.draw(|f| chat.draw_live(f, area, true)).unwrap();
        deltas += 1;
    }
    let total = start.elapsed();

    Sample {
        name,
        deltas,
        total,
    }
}

/// Split on char boundaries at ~`n` bytes (a token is ~4 chars).
fn split_chunks(s: &str, n: usize) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    while start < s.len() {
        let mut end = (start + n).min(s.len());
        while !s.is_char_boundary(end) {
            end += 1;
        }
        out.push(&s[start..end]);
        start = end;
    }
    out
}

fn prose(paragraphs: usize) -> String {
    let mut s = String::new();
    for i in 0..paragraphs {
        s.push_str(&format!(
            "This is paragraph {i} of a perfectly ordinary assistant reply. It \
             explains something at moderate length, wraps across several \
             terminal rows, and contains `inline code` plus a *little* emphasis \
             so the markdown renderer has real work to do.\n\n"
        ));
    }
    s
}

fn code_block(lines: usize) -> String {
    let mut s = String::from("Here is the patch:\n\n```rust\n");
    for i in 0..lines {
        s.push_str(&format!(
            "    let value_{i} = compute(&input[{i}]).unwrap_or_default();\n"
        ));
    }
    s.push_str("```\n\n");
    s
}

#[test]
fn stream_render_cost() {
    let samples = vec![
        // A short answer: the common case.
        measure("prose, 3 paragraphs", &prose(3), 4),
        // A long answer, still prose: the frozen-tail renderer should keep this
        // flat per delta because completed blocks stop being re-rendered.
        measure("prose, 30 paragraphs", &prose(30), 4),
        // A long fenced code block: markdown has NO safe split point inside a
        // fence, so the whole block stays in the unstable tail and is
        // re-rendered (and re-highlighted) on every single delta.
        measure("one 60-line code fence", &code_block(60), 4),
        measure("one 200-line code fence", &code_block(200), 4),
    ];

    println!("\n  scenario                       deltas   total       per delta");
    println!("  ---------------------------------------------------------------");
    for s in &samples {
        println!(
            "  {:<30} {:>6}   {:>7.1?}   {:>8.1} µs",
            s.name,
            s.deltas,
            s.total,
            s.per_delta_us()
        );
    }
    println!();

    // Guard rails, not targets. A frame budget at 60fps is 16_600µs; anything
    // in this table costing more than a millisecond per delta means a slow
    // trickle of tokens is spending real time per token.
    for s in &samples {
        assert!(
            s.per_delta_us() < 20_000.0,
            "{} costs {:.1}µs per delta — a single delta must never approach a \
             whole frame budget",
            s.name,
            s.per_delta_us()
        );
    }
}

/// The memoized highlighter must be **invisible**: what the user sees while a
/// code fence streams has to be cell-for-cell what a cold, un-memoized render
/// of the same prefix produces. Three TUI regressions on this project shipped
/// test-green, so this asserts the actual terminal buffer — every cell, symbol
/// and style — at every delta, not an intermediate data structure.
#[test]
fn the_streamed_preview_is_cell_identical_to_a_cold_render() {
    // Deliberately full of CROSS-LINE highlighter state — a block comment and a
    // multi-line string — because that is what a per-line-independent block
    // would fail to exercise: it is exactly the state the memo carries.
    let reply = "Here:\n\n```rust\n/* a block comment\n   that spans lines */\nfn f() {\n    let s = \"a string\n         across lines\";\n    let t = \"another { brace } string\";\n    /* second\n       comment */\n    println!(\"{}\", s);\n}\n```\n\ndone\n"
        .to_string();
    let area = Rect::new(0, 0, W, H);
    let prefixes: Vec<String> = {
        let mut acc = String::new();
        split_chunks(&reply, 4)
            .into_iter()
            .map(|p| {
                acc.push_str(p);
                acc.clone()
            })
            .collect()
    };

    // Pass 1 — the reference. Every prefix rendered from a COLD memo, i.e. by
    // the pre-change algorithm: highlight the whole block from line 1.
    let cold: Vec<ratatui::buffer::Buffer> = prefixes
        .iter()
        .map(|prefix| {
            crate::render::syntax::clear_highlight_memo();
            let mut term = Terminal::new(TestBackend::new(W, H)).unwrap();
            let mut chat = Chat::new();
            chat.update_streaming(prefix);
            term.draw(|f| chat.draw_live(f, area, true)).unwrap();
            term.backend().buffer().clone()
        })
        .collect();

    // Pass 2 — the real thing: ONE chat, ONE memo, streamed straight through.
    crate::render::syntax::clear_highlight_memo();
    let mut term = Terminal::new(TestBackend::new(W, H)).unwrap();
    let mut chat = Chat::new();
    for (prefix, want) in prefixes.iter().zip(&cold) {
        chat.update_streaming(prefix);
        term.draw(|f| chat.draw_live(f, area, true)).unwrap();
        assert_eq!(
            term.backend().buffer(),
            want,
            "the memoized streaming preview diverged from a cold render at {} bytes",
            prefix.len()
        );
    }
}

// ── draw_live cost vs streamed-buffer size ──────────────────────────────
//
// The live preview shows ~10 rows. If its cost tracks the size of the WHOLE
// streamed answer rather than the rows on screen, the TUI gets slower the
// longer the model talks — which is felt as input lag and uneven streaming.
// This measures that curve directly. Debug build: absolute numbers are
// inflated, the SHAPE is the finding.
#[test]
fn draw_live_cost_curve() {
    fn body(lines: usize) -> String {
        (0..lines)
            .map(|i| format!("Paragraph {i} about the deep ocean and its trenches.\n\n"))
            .collect()
    }

    // Warm lazies.
    {
        let mut warm = Chat::new();
        warm.update_streaming("hello\n");
        let _ = warm.streaming_height(W);
    }

    let area = Rect::new(0, 0, W, 12);
    println!("\n  lines |  per-FRAME draw_live |  per-DELTA (push+draw)");
    println!("  ------+----------------------+----------------------");
    for &n in &[50usize, 200, 800] {
        let text = body(n);

        // Per-frame cost with the cache already warm (pure redraw).
        let mut term = Terminal::new(TestBackend::new(W, 12)).unwrap();
        let mut chat = Chat::new();
        chat.update_streaming(&text);
        let _ = chat.streaming_height(W);
        term.draw(|f| chat.draw_live(f, area, true)).unwrap();
        let iters = 100;
        let t = Instant::now();
        for _ in 0..iters {
            term.draw(|f| chat.draw_live(f, area, true)).unwrap();
        }
        let per_frame = t.elapsed().as_secs_f64() * 1e6 / iters as f64;

        // Per-delta cost: append one token to a buffer of this size, then draw.
        let mut term2 = Terminal::new(TestBackend::new(W, 12)).unwrap();
        let mut chat2 = Chat::new();
        let mut buf = text.clone();
        chat2.update_streaming(&buf);
        let _ = chat2.streaming_height(W);
        let t2 = Instant::now();
        for _ in 0..iters {
            buf.push_str("word ");
            chat2.update_streaming(&buf);
            let _ = chat2.streaming_height(W);
            term2.draw(|f| chat2.draw_live(f, area, true)).unwrap();
        }
        let per_delta = t2.elapsed().as_secs_f64() * 1e6 / iters as f64;

        println!("  {n:5} | {per_frame:15.1} us | {per_delta:15.1} us");
    }
}
