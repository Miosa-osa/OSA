//! Ownership of the assistant text buffer for a turn.
//!
//! # Why this exists
//!
//! Assistant text reaches the TUI as a run of `streaming_token` deltas followed
//! by a terminal `agent_response` carrying the finished message. The old code
//! kept the deltas in a bare `String` field on `App` that nothing owned: every
//! delta of the turn was `push_str`'d onto it, and at turn end the finalizing
//! `agent_response` was *discarded* in favour of that accumulation.
//!
//! That is wrong in two ways, and both were observed:
//!
//! 1. **One turn can contain several assistant messages.** After a *text-only*
//!    response (no tool calls) the backend re-enters `ReactLoop.run/1` on many
//!    paths — the auto-continue nudge, the coding nudge, the verification gate,
//!    the goal verifier, the token-budget continue. Each re-entry is a fresh LLM
//!    generation, i.e. a *new assistant message*, but with no tool call between
//!    them nothing flushed the buffer. Generation 2's deltas landed straight on
//!    the end of generation 1's text, inside a single message, producing the
//!    reported `…Want me to implement Fix 2?Those are the three options. Want me
//!    to implement Fix 2, or were you…` — a superseded ending welded to its
//!    replacement with not even a space between them.
//!
//! 2. **The final message is authoritative and was being thrown away.** The
//!    backend post-processes the text it commits to the transcript (prompt-leak
//!    scrub, dead-phrase strip). Preferring the raw delta accumulation meant the
//!    rendered message could differ from the real one.
//!
//! # The model
//!
//! `message_id` is to an assistant message what `tool_call_id` is to a tool
//! call: the backend's stable identity, minted per LLM generation. It rides
//! every `streaming_token` and the terminal `agent_response`.
//!
//! * The buffer belongs to **exactly one** assistant message.
//! * A delta carrying a *different* id means the previous generation is over:
//!   its text is handed back to be committed as its own block, and the buffer
//!   restarts empty. Nothing is concatenated, and nothing is lost.
//! * Finalizing **replaces** the buffer with the backend's text — it never
//!   appends to it.
//! * Finalizing the same message twice is a no-op, so an SSE replay or a second
//!   code path finalizing the same turn cannot double-render it.
//!
//! `message_id` is `Option` on purpose: a new TUI must still work against an
//! older backend that does not send one. With no id the splitting is inert (the
//! legacy single-buffer behaviour) and duplicate detection falls back to an
//! exact repeat of the identical final text.
//!
//! Deliberately NOT done here: trimming a common prefix/suffix between the
//! accumulation and the final on a *guess*. What IS done is exact bookkeeping —
//! see "Settling" below: the buffer knows precisely which bytes it already put
//! on screen, and only subtracts those.
//!
//! # Settling — completed blocks flow into scrollback as they complete
//!
//! A reply used to live in the capped inline preview for the whole turn and
//! only reach the terminal's native scrollback at `finalize`. Two things follow
//! from that, and both were reported: a long answer *appeared* all at once when
//! the turn ended, and while the turn ran, tool-progress rows appended below
//! the prose pushed the prose off the top of the capped region, where it could
//! never be recovered — the live region is not scrollback.
//!
//! So a block is **settled** as soon as markdown says it can never change
//! again: `find_frozen_boundary` (the same depth-0 blank-line checkpoint the
//! streaming renderer freezes on, which is proven there to make
//! `render(src[..B]) ++ render(src[B..]) == render(src)`) marks how much of the
//! accumulation is complete, and everything up to it is committed through the
//! ordinary `commit_assistant_block` path. `settled` counts those bytes; the
//! preview then shows only `tail()`, the still-unterminated block.
//!
//! Two rules keep this compatible with "the final replaces the accumulation":
//!
//! * **The gate.** `settle_guard::may_settle` decides whether the backend's
//!   output guardrails could still rewrite what we are about to commit; a
//!   `false` is sticky for the rest of the message. See that module — it is
//!   where the reasoning about `maybe_scrub_prompt_leak` /
//!   `maybe_strip_dead_phrases` lives.
//! * **The subtraction.** `finalize` emits the final *minus the bytes already
//!   committed*, matched with `common_prefix_modulo_whitespace` and backed off
//!   to a block boundary when the final genuinely diverged. Nothing is rendered
//!   twice, and nothing is silently dropped.

/// What a finalizing `agent_response` should render.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Finalize {
    /// This finalization was already applied — render nothing.
    Duplicate,
    /// Render this text as the assistant message. May be empty (nothing to show).
    Emit(String),
}

#[derive(Debug)]
pub(crate) struct AssistantStream {
    /// Deltas accumulated for the message identified by `msg_id`.
    buf: String,
    /// Bytes of `buf` already committed to native scrollback by [`settle`]. Always
    /// a settle boundary, hence a char boundary and a line start.
    ///
    /// [`settle`]: AssistantStream::settle
    settled: usize,
    /// Whether completed blocks of THIS message may still be committed early.
    /// Once cleared it stays cleared until the message ends (see the module
    /// docs and `settle_guard`).
    settle_ok: bool,
    /// Identity of the message currently accumulating, when the backend sends one.
    msg_id: Option<String>,
    /// Identity of the last message finalized this turn (`None` for an id-less backend).
    finalized_id: Option<String>,
    /// Text of the last finalization — the id-less backend's duplicate check.
    finalized_text: Option<String>,
}

impl Default for AssistantStream {
    fn default() -> Self {
        Self {
            buf: String::new(),
            settled: 0,
            settle_ok: true,
            msg_id: None,
            finalized_id: None,
            finalized_text: None,
        }
    }
}

impl AssistantStream {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    /// Everything accumulated so far for the current message, settled or not.
    pub(crate) fn text(&self) -> &str {
        &self.buf
    }

    /// The part of the current message that is NOT yet in native scrollback —
    /// what the live preview must show, and what a flush hands over.
    pub(crate) fn tail(&self) -> &str {
        &self.buf[self.settled..]
    }

    /// True when nothing is waiting to be rendered: every accumulated byte has
    /// already been committed (or none arrived). This is the "is there text to
    /// flush?" question every caller actually asks.
    pub(crate) fn is_empty(&self) -> bool {
        self.buf.len() == self.settled
    }

    /// Bytes already committed to scrollback for the current message.
    #[cfg(test)]
    pub(crate) fn settled_bytes(&self) -> usize {
        self.settled
    }

    /// Hand back the next run of **completed** markdown blocks, which the caller
    /// must commit to scrollback; `None` when nothing new is complete, or when
    /// the guardrail gate is shut.
    ///
    /// Idempotent in the sense that matters: a byte is returned at most once for
    /// the lifetime of the message.
    pub(crate) fn settle(&mut self) -> Option<String> {
        if !self.settle_ok {
            return None;
        }
        // The gate is evaluated against the WHOLE accumulation, not just the
        // candidate region: both guardrails are triggered by text anywhere in
        // the response, so a phrase already visible in the unsettled tail must
        // stop the blocks in front of it from going out.
        if !crate::app::settle_guard::may_settle(&self.buf) {
            self.settle_ok = false;
            return None;
        }
        let end = crate::render::markdown_stream::find_frozen_boundary(&self.buf);
        if end <= self.settled {
            return None;
        }
        let out = self.buf[self.settled..end].to_string();
        self.settled = end;
        Some(out)
    }

    /// Accept a streamed delta.
    ///
    /// Returns `Some(previous)` when this delta opens a NEW assistant message
    /// while an uncommitted one was still buffered: that text belongs to the
    /// superseded generation and the caller must commit it as its own block
    /// before the new message starts accumulating. Blocks of the superseded
    /// generation that already settled into scrollback are NOT handed back —
    /// they are on screen, and handing them back would render them twice.
    pub(crate) fn push(&mut self, message_id: Option<&str>, text: &str) -> Option<String> {
        let new_generation = matches!(
            (self.msg_id.as_deref(), message_id),
            (Some(current), Some(incoming)) if current != incoming
        );

        let superseded = if new_generation {
            let rest = self.buf[self.settled..].to_string();
            self.buf.clear();
            self.settled = 0;
            // A fresh generation is a fresh message: the previous one's gate
            // decision says nothing about this one.
            self.settle_ok = true;
            if rest.is_empty() {
                None
            } else {
                Some(rest)
            }
        } else {
            None
        };

        if let Some(id) = message_id {
            self.msg_id = Some(id.to_string());
        }
        self.buf.push_str(text);
        superseded
    }

    /// Take the *uncommitted* buffered text for an interleaving flush (a tool
    /// call splits one message into several rendered blocks). Same generation —
    /// the identity is kept so a later delta for it is not mistaken for a new
    /// message, and so is `settle_ok`, since the guardrails still judge the
    /// whole of this message.
    pub(crate) fn take(&mut self) -> String {
        let out = self.buf[self.settled..].to_string();
        self.buf.clear();
        self.settled = 0;
        out
    }

    /// Apply the turn's terminal `agent_response`.
    ///
    /// The backend's text REPLACES the accumulation for the message it
    /// finalizes; the accumulation survives only as a fallback when the final
    /// carries no text at all. Repeating a finalization is a no-op.
    ///
    /// What is *emitted* is the final minus whatever [`settle`] already put into
    /// native scrollback, so a reply the user has been reading block by block
    /// does not re-appear wholesale at turn end. The duplicate bookkeeping still
    /// records the FULL final, so a replayed delivery is recognised.
    ///
    /// [`settle`]: AssistantStream::settle
    pub(crate) fn finalize(&mut self, message_id: Option<&str>, final_text: String) -> Finalize {
        if self.is_duplicate(message_id, &final_text) {
            return Finalize::Duplicate;
        }

        let settled = std::mem::replace(&mut self.settled, 0);
        self.settle_ok = true;
        let streamed = std::mem::take(&mut self.buf);
        let out = if final_text.trim().is_empty() {
            // No authoritative text: the accumulation stands in for it, and the
            // part already on screen is dropped rather than repeated.
            streamed[settled..].to_string()
        } else {
            final_text
        };

        self.finalized_id = message_id.map(str::to_string);
        self.finalized_text = Some(out.clone());
        self.msg_id = None;
        Finalize::Emit(subtract_committed(&out, &streamed[..settled]))
    }

    fn is_duplicate(&self, message_id: Option<&str>, final_text: &str) -> bool {
        match (self.finalized_id.as_deref(), message_id) {
            // Both sides carry an id — identity decides, and only identity.
            // Different ids are two genuinely different messages, however
            // similar their text.
            (Some(previous), Some(incoming)) => previous == incoming,
            // Legacy backend (or a producer with no generation behind it):
            // only a byte-identical repeat of the same non-empty final counts
            // as the same delivery.
            _ => !final_text.is_empty() && self.finalized_text.as_deref() == Some(final_text),
        }
    }

    /// Drop the partial text but keep this turn's finalization history, so a
    /// late duplicate `agent_response` is still recognised.
    pub(crate) fn clear_buf(&mut self) {
        self.buf.clear();
        self.settled = 0;
        self.settle_ok = true;
        self.msg_id = None;
    }

    /// Full per-turn reset. Called when a new turn opens (or the session /
    /// conversation is replaced), never mid-turn.
    pub(crate) fn reset(&mut self) {
        self.buf.clear();
        self.settled = 0;
        self.settle_ok = true;
        self.msg_id = None;
        self.finalized_id = None;
        self.finalized_text = None;
    }
}

/// `final_text` with the leading run that is already in native scrollback
/// removed.
///
/// Normally `committed` is a byte-exact prefix of `final_text` (the final IS the
/// accumulation) and this is a plain slice. The two ways it can diverge are both
/// handled without ever rendering a byte twice on the happy path:
///
/// * **Re-whitespaced.** A dead phrase arriving in the unsettled tail makes the
///   backend run its whitespace normalisation over the *whole* response, which
///   reaches back into already-committed text.
///   [`common_prefix_modulo_whitespace`] recognises it anyway.
/// * **Genuinely different text** — most sharply, the prompt-leak scrub, which
///   throws the response away and substitutes a one-line refusal. Then no prefix
///   matches; we back off to the largest *block boundary* inside `committed`
///   that the final does agree with (often zero) and emit everything after it.
///   Backing off to a boundary rather than to an arbitrary character is what
///   keeps a model that legitimately repeats itself from being truncated
///   mid-sentence.
///
/// [`common_prefix_modulo_whitespace`]: crate::app::settle_guard::common_prefix_modulo_whitespace
fn subtract_committed(final_text: &str, committed: &str) -> String {
    use crate::app::settle_guard::common_prefix_modulo_whitespace;
    use crate::render::markdown_stream::find_frozen_boundary;

    if committed.is_empty() {
        return final_text.to_string();
    }
    // Fast path: the final is the accumulation.
    if let Some(stripped) = final_text.strip_prefix(committed) {
        return stripped.to_string();
    }
    if let Some(cut) = common_prefix_modulo_whitespace(final_text, committed) {
        return final_text[cut..].to_string();
    }
    // Diverged. Retreat one settled block at a time until the final agrees.
    let mut end = committed.len();
    while end > 0 {
        end = find_frozen_boundary(&committed[..end.saturating_sub(1)]);
        if end == 0 {
            break;
        }
        if let Some(cut) = common_prefix_modulo_whitespace(final_text, &committed[..end]) {
            return final_text[cut..].to_string();
        }
    }
    final_text.to_string()
}

/// Commit one assistant block to the chat, honouring the "◈ OSA" header-once
/// rule: the first block of a turn carries the header, every later block is a
/// header-less continuation so one answer never renders as several labelled
/// blocks.
///
/// The single place a block reaches the chat — every producer (a tool call
/// splitting the message, a superseded generation, the final `agent_response`)
/// goes through here, so they cannot drift apart.
///
/// It is also the one chokepoint where internal control markup is stripped
/// from assistant text. Background completions re-enter the agent's context as
/// a `<task-notification>` XML block and models echo them back into their own
/// reply; the observed leak rendered a mangled copy of one inside a normal
/// assistant message, gutter and all. The backend cannot prevent that (the
/// block MUST be in the model's context for the mechanism to work, and the
/// text is emitted from several `agent_response` sites), so the render layer
/// refuses to draw it — here, once, for every producer.
pub(crate) fn commit_assistant_block(
    chat: &mut crate::components::chat::Chat,
    header_sent: &mut bool,
    text: &str,
    signal: Option<&crate::client::types::Signal>,
) {
    let Some(text) = clean_for_commit(text) else {
        return;
    };
    // A block ends whatever chunk flow was open: it is its own unit, with its
    // own margin above it.
    chat.end_agent_chunk_flow();
    if *header_sent {
        chat.add_agent_continuation(&text);
    } else {
        chat.add_agent_message(&text, signal);
        *header_sent = true;
    }
}

/// Commit one **settled chunk** of an assistant message — a run of markdown
/// blocks that is complete and can never change again, handed to native
/// scrollback while the rest of the reply is still streaming.
///
/// Differs from [`commit_assistant_block`] in exactly one way, and it is load
/// bearing: the text goes in verbatim, separator and all, because a chunk
/// boundary is a proven safe render split point. See `Chat::add_agent_chunk`.
pub(crate) fn commit_assistant_chunk(
    chat: &mut crate::components::chat::Chat,
    header_sent: &mut bool,
    text: &str,
    signal: Option<&crate::client::types::Signal>,
) {
    // Control markup is stripped here too, but a chunk whose entire content was
    // plumbing must not silently swallow its block separator — dropping it whole
    // is right, and the surrounding chunks still join correctly because each
    // carries its own terminator.
    let Some(text) = clean_for_commit(text) else {
        return;
    };
    chat.add_agent_chunk(&text, !*header_sent, signal);
    *header_sent = true;
}

/// Shared pre-commit cleanup: strip internal control markup, and report
/// "nothing to render" for text that was only ever plumbing.
///
/// Returns the text unchanged (borrowed) in the overwhelmingly common case that
/// no control tag is present, so the verbatim guarantee chunks depend on holds.
fn clean_for_commit(text: &str) -> Option<std::borrow::Cow<'_, str>> {
    let has_markup = crate::tools::CONTROL_TAGS
        .iter()
        .any(|t| text.contains(&format!("<{t}>")));
    if !has_markup {
        return if text.is_empty() {
            None
        } else {
            Some(std::borrow::Cow::Borrowed(text))
        };
    }
    let cleaned = crate::tools::strip_control_markup(text);
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(std::borrow::Cow::Owned(trimmed.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn deltas(s: &mut AssistantStream, id: Option<&str>, parts: &[&str]) -> Vec<String> {
        parts.iter().filter_map(|p| s.push(id, p)).collect()
    }

    #[test]
    fn final_replaces_the_streamed_accumulation_exactly_once() {
        // The reported bug, reduced: deltas stream, then a final whose text
        // DIFFERS from the concatenated deltas arrives. The rendered message
        // must be the final, verbatim, once — never final appended to deltas.
        let mut s = AssistantStream::new();
        deltas(&mut s, Some("m1"), &["Those are ", "the three optionss."]);

        let out = s.finalize(Some("m1"), "Those are the three options.".to_string());

        assert_eq!(out, Finalize::Emit("Those are the three options.".to_string()));
        let Finalize::Emit(text) = out else { unreachable!() };
        // Exactly once: the accumulation must not survive anywhere in it.
        assert_eq!(text.matches("Those are the three options.").count(), 1);
        assert!(!text.contains("optionss"), "stale accumulation leaked into the final");
        assert!(s.is_empty(), "buffer must be released to the final");
    }

    #[test]
    fn double_finalize_is_idempotent() {
        let mut s = AssistantStream::new();
        deltas(&mut s, Some("m1"), &["hello"]);
        assert_eq!(
            s.finalize(Some("m1"), "hello world".into()),
            Finalize::Emit("hello world".into())
        );
        // Same message finalized again (SSE replay, or a second code path
        // ending the same turn) renders nothing.
        assert_eq!(s.finalize(Some("m1"), "hello world".into()), Finalize::Duplicate);
        assert_eq!(s.finalize(Some("m1"), "hello world".into()), Finalize::Duplicate);
    }

    #[test]
    fn double_finalize_is_idempotent_without_ids() {
        // Older backend: no message_id on the wire. A byte-identical repeat is
        // still recognised as the same delivery.
        let mut s = AssistantStream::new();
        deltas(&mut s, None, &["hi"]);
        assert_eq!(s.finalize(None, "hi there".into()), Finalize::Emit("hi there".into()));
        assert_eq!(s.finalize(None, "hi there".into()), Finalize::Duplicate);
        // …but a DIFFERENT final is a different message and still renders.
        assert_eq!(
            s.finalize(None, "something else".into()),
            Finalize::Emit("something else".into())
        );
    }

    #[test]
    fn final_with_no_preceding_deltas_renders_the_final() {
        let mut s = AssistantStream::new();
        assert_eq!(
            s.finalize(Some("m1"), "the whole answer".into()),
            Finalize::Emit("the whole answer".into())
        );
    }

    #[test]
    fn empty_final_falls_back_to_the_accumulation() {
        // A finalization that carries no text must not erase what streamed.
        let mut s = AssistantStream::new();
        deltas(&mut s, Some("m1"), &["streamed only"]);
        assert_eq!(
            s.finalize(Some("m1"), "   ".into()),
            Finalize::Emit("streamed only".into())
        );
    }

    #[test]
    fn a_new_generation_hands_back_the_superseded_text_instead_of_concatenating() {
        // Exactly the observed shape: generation 1 ends with a question, the
        // backend nudges, generation 2 rewrites the ending. The two must never
        // end up welded together in one buffer.
        let mut s = AssistantStream::new();
        deltas(&mut s, Some("m1"), &["My recommendation: Do Fix 2. ", "Want me to implement Fix 2?"]);

        let superseded = s.push(Some("m2"), "Those are the three options. ");
        assert_eq!(
            superseded.as_deref(),
            Some("My recommendation: Do Fix 2. Want me to implement Fix 2?"),
            "generation 1 must be handed back for its own block"
        );
        s.push(Some("m2"), "Want me to implement Fix 2, or were you just scoping?");

        assert_eq!(
            s.text(),
            "Those are the three options. Want me to implement Fix 2, or were you just scoping?",
            "generation 2 must start from an empty buffer"
        );
        assert!(
            !s.text().contains("My recommendation"),
            "the superseded generation must not be concatenated onto its replacement"
        );
    }

    #[test]
    fn same_generation_deltas_never_split() {
        let mut s = AssistantStream::new();
        let flushes = deltas(&mut s, Some("m1"), &["a", "b", "c"]);
        assert!(flushes.is_empty());
        assert_eq!(s.text(), "abc");
    }

    #[test]
    fn missing_ids_keep_the_legacy_single_buffer_behaviour() {
        // Old backend: no ids, so the TUI cannot split — it must at least not
        // split at random or lose text.
        let mut s = AssistantStream::new();
        let flushes = deltas(&mut s, None, &["a", "b", "c"]);
        assert!(flushes.is_empty());
        assert_eq!(s.text(), "abc");
    }

    #[test]
    fn a_tool_flush_keeps_the_generation_identity() {
        // A tool call splits one message into blocks; the deltas that follow
        // belong to the SAME message and must not be reported as a new one.
        let mut s = AssistantStream::new();
        s.push(Some("m1"), "before the tool");
        assert_eq!(s.take(), "before the tool");
        assert_eq!(s.push(Some("m1"), "after the tool"), None);
        assert_eq!(s.text(), "after the tool");
    }

    #[test]
    fn reset_forgets_the_finalization_so_the_next_turn_renders() {
        let mut s = AssistantStream::new();
        s.push(Some("m1"), "x");
        assert!(matches!(s.finalize(Some("m1"), "done".into()), Finalize::Emit(_)));
        s.reset();
        // A new turn that happens to produce the identical text still renders.
        assert_eq!(s.finalize(None, "done".into()), Finalize::Emit("done".into()));
    }

    // ── Rendered-output regressions ──────────────────────────────────────
    //
    // The tests above pin the buffer's ownership rules; these pin what the user
    // actually READS, by driving the same `AssistantStream` + `commit_assistant_block`
    // pair the event handlers use and asserting on the chat's committed blocks.

    use crate::components::chat::Chat;

    /// Mirrors the `StreamingToken` handler: push the delta, and commit any
    /// generation it superseded.
    fn on_delta(
        chat: &mut Chat,
        s: &mut AssistantStream,
        header: &mut bool,
        message_id: Option<&str>,
        text: &str,
    ) {
        if let Some(superseded) = s.push(message_id, text) {
            chat.clear_streaming();
            commit_assistant_block(chat, header, &superseded, None);
        }
        chat.update_streaming(s.text());
    }

    /// Mirrors the `AgentResponse` handler: finalize, then commit — or render
    /// nothing at all if this finalization was already applied.
    fn on_final(
        chat: &mut Chat,
        s: &mut AssistantStream,
        header: &mut bool,
        message_id: Option<&str>,
        text: &str,
    ) {
        chat.clear_streaming();
        match s.finalize(message_id, text.to_string()) {
            Finalize::Duplicate => {}
            Finalize::Emit(final_text) => commit_assistant_block(chat, header, &final_text, None),
        }
        s.clear_buf();
    }

    /// A well-formed `<task-notification>`, as `Agent.TaskNotifications.to_xml/1`
    /// builds it, plus the MANGLED re-typing a model produced when it echoed one
    /// back into its own reply (mismatched `</status>`, duplicated element).
    const NOTIF: &str = "<task-notification>\n  <task-id>bg_5g5byuj8</task-id>\n  <status>done</status>\n  <output-file>/tmp/osa/s/tasks/bg_5g5byuj8.out</output-file>\n</task-notification>";
    const MANGLED_NOTIF: &str = "<task-notification> <task-id>bg_5g5byuj8</task-id> <status>done</status>\n<output-file>/var/var/folders/x/T/osa/s/tasks/bg_5g5byuj8.out</status> <output-file>dup</output-file> <summary>Background command 'mix compile' completed (exit code 0)</summary>\n</task-notification>";

    #[test]
    fn control_markup_never_reaches_a_rendered_assistant_message() {
        for notif in [NOTIF, MANGLED_NOTIF] {
            let mut chat = Chat::new();
            let mut s = AssistantStream::new();
            let mut header = false;

            let echoed = format!("The compile finished.\n{notif}\nI'll continue.");
            on_final(&mut chat, &mut s, &mut header, Some("m1"), &echoed);

            let joined = chat.agent_blocks().join("\n");
            assert!(joined.contains("The compile finished."));
            assert!(joined.contains("I'll continue."));
            for needle in ["task-notification", "task-id", "output-file", "bg_5g5byuj8"] {
                assert!(!joined.contains(needle), "leaked {needle} in rendered text: {joined}");
            }
        }
    }

    #[test]
    fn an_assistant_message_that_is_only_control_markup_renders_nothing() {
        let mut chat = Chat::new();
        let mut s = AssistantStream::new();
        let mut header = false;

        on_final(&mut chat, &mut s, &mut header, Some("m1"), NOTIF);

        assert!(chat.agent_blocks().is_empty(), "a pure-plumbing message must not render");
        assert!(!header, "a suppressed block must not consume the ◈ OSA header");
    }

    #[test]
    fn rendered_message_is_the_final_exactly_once_when_it_differs_from_the_deltas() {
        let mut chat = Chat::new();
        let mut s = AssistantStream::new();
        let mut header = false;

        on_delta(&mut chat, &mut s, &mut header, Some("m1"), "Those are the ");
        on_delta(&mut chat, &mut s, &mut header, Some("m1"), "three optionss. Want me to?");
        // The backend's final differs from the concatenated deltas (it is the
        // post-processed text the transcript actually stores).
        let final_text = "Those are the three options. Want me to implement Fix 2?";
        on_final(&mut chat, &mut s, &mut header, Some("m1"), final_text);

        let blocks = chat.agent_blocks();
        assert_eq!(blocks, vec![final_text.to_string()], "the final must replace the deltas");
        let joined = blocks.join("");
        assert_eq!(joined.matches("Want me to implement Fix 2?").count(), 1);
        assert!(!joined.contains("optionss"), "the superseded delta text must not survive");
    }

    #[test]
    fn a_regenerated_answer_renders_as_two_blocks_never_welded_together() {
        // The reported bug end to end: generation 1 streams a full answer, the
        // backend nudges (no tool call in between), generation 2 rewrites the
        // ending, and the turn finalizes on generation 2.
        let mut chat = Chat::new();
        let mut s = AssistantStream::new();
        let mut header = false;

        on_delta(&mut chat, &mut s, &mut header, Some("m1"), "My recommendation: Do Fix 2. ");
        on_delta(&mut chat, &mut s, &mut header, Some("m1"), "Want me to implement Fix 2?");
        on_delta(&mut chat, &mut s, &mut header, Some("m2"), "Those are the three options. ");
        on_delta(&mut chat, &mut s, &mut header, Some("m2"), "Want me to implement Fix 2, or were you just scoping?");
        on_final(
            &mut chat,
            &mut s,
            &mut header,
            Some("m2"),
            "Those are the three options. Want me to implement Fix 2, or were you just scoping?",
        );

        let blocks = chat.agent_blocks();
        assert_eq!(blocks.len(), 2, "each generation is its own block");
        assert_eq!(blocks[0], "My recommendation: Do Fix 2. Want me to implement Fix 2?");
        assert_eq!(
            blocks[1],
            "Those are the three options. Want me to implement Fix 2, or were you just scoping?"
        );
        // The exact reported corruption: a fragment immediately followed by a
        // longer version of itself with no separator at all.
        assert!(
            !blocks
                .iter()
                .any(|b| b.contains("Fix 2?Those are the three options")),
            "a superseded generation must never be welded to its replacement"
        );
    }

    #[test]
    fn a_repeat_final_renders_nothing_the_second_time() {
        let mut chat = Chat::new();
        let mut s = AssistantStream::new();
        let mut header = false;

        on_delta(&mut chat, &mut s, &mut header, Some("m1"), "partial");
        on_final(&mut chat, &mut s, &mut header, Some("m1"), "the answer");
        // SSE replay / a second terminal code path delivering the same finish.
        on_final(&mut chat, &mut s, &mut header, Some("m1"), "the answer");

        assert_eq!(chat.agent_blocks(), vec!["the answer".to_string()]);
    }

    #[test]
    fn a_final_with_no_preceding_deltas_renders_once_under_the_header() {
        let mut chat = Chat::new();
        let mut s = AssistantStream::new();
        let mut header = false;

        on_final(&mut chat, &mut s, &mut header, Some("m1"), "no streaming happened");

        assert_eq!(chat.agent_blocks(), vec!["no streaming happened".to_string()]);
        assert!(header, "the first block of the turn carries the ◈ OSA header");
    }

    #[test]
    fn an_older_backend_with_no_ids_still_renders_the_final_once() {
        // Legacy wire format: no message_id anywhere. Splitting is inert, but
        // the final must still replace the accumulation rather than append.
        let mut chat = Chat::new();
        let mut s = AssistantStream::new();
        let mut header = false;

        on_delta(&mut chat, &mut s, &mut header, None, "streamed ");
        on_delta(&mut chat, &mut s, &mut header, None, "text");
        on_final(&mut chat, &mut s, &mut header, None, "final text");
        on_final(&mut chat, &mut s, &mut header, None, "final text");

        assert_eq!(chat.agent_blocks(), vec!["final text".to_string()]);
    }

    #[test]
    fn finalizing_a_second_generation_is_not_a_duplicate() {
        let mut s = AssistantStream::new();
        s.push(Some("m1"), "first");
        assert!(matches!(s.finalize(Some("m1"), "first".into()), Finalize::Emit(_)));
        // Mid-turn finalization followed by a genuinely new generation.
        s.push(Some("m2"), "second");
        assert_eq!(s.finalize(Some("m2"), "second".into()), Finalize::Emit("second".into()));
    }
}
