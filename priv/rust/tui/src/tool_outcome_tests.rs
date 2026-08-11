//! Regression tests for how a tool call's OUTCOME reads on screen.
//!
//! Two defects lived here, both invisible to the ~1160 tests that already
//! passed, and both of the same shape: state encoded only as colour.
//!
//!   * `Success` and `Error` shared the `●` glyph, so a failed call was
//!     indistinguishable from a successful one under `NO_COLOR`, on a
//!     monochrome terminal, or to a red/green-colour-blind reader.
//!   * Renderers summarised `result` as CONTENT without consulting
//!     `opts.status`, so a failed read rendered `⎿ Read 1 line` and a failed
//!     grep claimed it had `Found 1 line` — the "line" being the error text.

#[cfg(test)]
mod outcome_is_legible_without_colour {
    use crate::tools::{render_tool, RenderOpts, ToolStatus};

    /// Flatten a rendered tool cell to plain text — i.e. exactly what survives
    /// when every style is stripped.
    fn plain(name: &str, args: &str, result: &str, status: ToolStatus, ms: u64) -> String {
        let opts = RenderOpts {
            status,
            width: 90,
            expanded: false,
            compact: true,
            spinner_frame: None,
            duration_ms: ms,
            truncated: false,
        };
        render_tool(name, args, result, &opts)
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn a_failed_read_is_not_reported_as_a_successful_read() {
        let out = plain(
            "file_read",
            r#"{"path":"/tmp/x.rs"}"#,
            "Error: ENOENT",
            ToolStatus::Error,
            40,
        );
        assert!(
            out.contains("Error: ENOENT"),
            "the failure must be on screen as text: {out:?}"
        );
        assert!(
            !out.contains("Read 1 line"),
            "the error message was counted as file content: {out:?}"
        );
    }

    #[test]
    fn a_failed_grep_does_not_claim_it_found_anything() {
        let out = plain(
            "file_grep",
            r#"{"pattern":"todo"}"#,
            "Error: bad regex",
            ToolStatus::Error,
            12,
        );
        assert!(out.contains("Error: bad regex"), "{out:?}");
        assert!(
            !out.contains("Found"),
            "a failed search must not report finds: {out:?}"
        );
    }

    #[test]
    fn a_failed_edit_says_why() {
        let out = plain(
            "file_edit",
            r#"{"path":"/tmp/x.rs"}"#,
            "Error: no match",
            ToolStatus::Error,
            30,
        );
        assert!(out.contains("Error: no match"), "{out:?}");
    }

    /// Bash already surfaces its failure text in a richer cell; the override
    /// must leave that alone rather than flattening it.
    fn contains_once(hay: &str, needle: &str) -> bool {
        hay.matches(needle).count() == 1
    }

    #[test]
    fn bash_keeps_its_own_failure_cell() {
        let out = plain(
            "shell_execute",
            r#"{"command":"make"}"#,
            "Error: exit 2",
            ToolStatus::Error,
            2500,
        );
        assert!(
            contains_once(&out, "Error: exit 2"),
            "bash's own body should be kept, not duplicated: {out:?}"
        );
    }

    #[test]
    fn success_and_error_do_not_share_a_glyph() {
        let ok = plain("file_read", r#"{"path":"/a"}"#, "x", ToolStatus::Success, 5);
        let err = plain("file_read", r#"{"path":"/a"}"#, "Error: nope", ToolStatus::Error, 5);
        let ok_glyph = ok.chars().next().unwrap();
        let err_glyph = err.chars().next().unwrap();
        assert_ne!(
            ok_glyph, err_glyph,
            "outcome must not be carried by colour alone (ok={ok_glyph:?} err={err_glyph:?})"
        );
    }

    /// The header keeps carrying the facts a failure does not invalidate: which
    /// tool ran, on what, and for how long.
    #[test]
    fn a_failed_call_still_reports_its_tool_target_and_duration() {
        let out = plain(
            "file_read",
            r#"{"path":"/tmp/x.rs"}"#,
            "Error: ENOENT",
            ToolStatus::Error,
            40,
        );
        assert!(out.contains("Read"), "{out:?}");
        assert!(out.contains("/tmp/x.rs"), "{out:?}");
        assert!(out.contains("40ms"), "{out:?}");
    }
}

#[cfg(test)]
mod collapsed_runs_report_failure {
    use crate::tools::collapse::{classify, Accumulator};

    fn text(acc: &mut Accumulator) -> String {
        acc.take_summary_line()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .unwrap_or_default()
    }

    #[test]
    fn a_failed_call_in_a_collapsed_run_says_so_in_words() {
        let mut acc = Accumulator::default();
        let kind = classify("file_grep", r#"{"pattern":"todo"}"#);
        acc.add(&kind, r#"{"pattern":"todo"}"#, false);
        let out = text(&mut acc);
        assert!(
            out.contains("failed"),
            "a failed collapsed run was signalled by bullet colour alone: {out:?}"
        );
    }

    #[test]
    fn a_clean_collapsed_run_is_not_labelled_failed() {
        let mut acc = Accumulator::default();
        let kind = classify("file_grep", r#"{"pattern":"todo"}"#);
        acc.add(&kind, r#"{"pattern":"todo"}"#, true);
        let out = text(&mut acc);
        assert!(!out.contains("failed"), "{out:?}");
        assert!(out.contains("Searched"), "{out:?}");
    }
}
