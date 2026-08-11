//! Serialized permission prompts.
//!
//! The backend runs tool calls in PARALLEL (see `pending_key` in
//! `handle_backend.rs`: every shell call is named `shell_execute`, so only the
//! per-call id is an identity), which means two `PermissionRequired` events can
//! be in flight at once.
//!
//! A single `Option<Permissions>` slot answered that with silent replacement:
//! request B's dialog overwrote request A's while the user was reading A, and
//! the next keypress was dispatched against B's `request_id`. The user approved
//! an action they never saw, and A hung until it timed out.
//!
//! This type makes that unrepresentable. There is exactly ONE displayed request;
//! anything arriving while it is up is QUEUED behind it. The id answered is read
//! out of the displayed dialog itself — there is no second mutable field that
//! could drift away from the content on screen.

use std::collections::VecDeque;

use crate::dialogs::permissions::Permissions;

/// One backend permission ask, held verbatim until it is its turn to be shown.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct PermissionRequest {
    /// Opaque backend id. The ONLY thing that resumes the parked tool call.
    pub request_id: String,
    pub tool: String,
    pub args: String,
    pub target: Option<String>,
    pub old_content: Option<String>,
    pub new_content: Option<String>,
    pub warning: Option<String>,
    pub reason: Option<String>,
}

impl PermissionRequest {
    /// Build the dialog for this request. Every field the user reads before
    /// deciding is populated here, so a queued request that becomes visible
    /// later carries ITS OWN content rather than leftovers from its predecessor.
    pub fn into_dialog(self) -> Permissions {
        let mut dialog = Permissions::new();
        // `set_tool` resets target/diff/meta, so it must come first.
        dialog.set_tool(self.tool, self.args, self.request_id);
        dialog.set_target(self.target);
        if let (Some(old), Some(new)) = (self.old_content, self.new_content) {
            dialog.set_diff(old, new);
        }
        dialog.set_meta(self.warning, self.reason);
        dialog
    }
}

/// What [`PermissionQueue::submit`] did with a request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Submission {
    /// Nothing was pending — the request is now on screen. The caller should
    /// open the overlay / raise the "parked on you" cue.
    Displayed,
    /// Something else is on screen; this one waits its turn. The visible dialog
    /// is untouched.
    Queued,
    /// Same `request_id` as the displayed one or one already queued (reconnect
    /// replay). Dropped.
    Duplicate,
}

/// The id that was just answered, plus whether the prompt band stays up.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Answered {
    /// Read out of the dialog the user was actually looking at.
    pub request_id: String,
    /// True when another request was popped into view: stay in the overlay.
    pub has_more: bool,
}

/// One visible permission prompt plus the asks stacked behind it.
#[derive(Default)]
pub struct PermissionQueue {
    displayed: Option<Permissions>,
    pending: VecDeque<PermissionRequest>,
}

impl PermissionQueue {
    pub fn new() -> Self {
        Self::default()
    }

    /// Show `req` if nothing is up, otherwise queue it behind what is.
    ///
    /// Never replaces the visible dialog — that replacement was the bug.
    pub fn submit(&mut self, req: PermissionRequest) -> Submission {
        if self.contains(&req.request_id) {
            return Submission::Duplicate;
        }
        if self.displayed.is_none() {
            self.displayed = Some(req.into_dialog());
            Submission::Displayed
        } else {
            self.pending.push_back(req);
            Submission::Queued
        }
    }

    /// Whether `request_id` is already displayed or already queued.
    pub fn contains(&self, request_id: &str) -> bool {
        self.current_request_id() == Some(request_id)
            || self.pending.iter().any(|r| r.request_id == request_id)
    }

    /// The dialog the user is looking at.
    pub fn displayed(&self) -> Option<&Permissions> {
        self.displayed.as_ref()
    }

    pub fn displayed_mut(&mut self) -> Option<&mut Permissions> {
        self.displayed.as_mut()
    }

    /// True while any prompt is on screen.
    pub fn is_active(&self) -> bool {
        self.displayed.is_some()
    }

    /// The id of the request ON SCREEN — sourced from the dialog itself so the
    /// content the user read and the id that gets answered cannot diverge.
    pub fn current_request_id(&self) -> Option<&str> {
        self.displayed.as_ref().map(|d| d.request_id())
    }

    /// Number of asks waiting behind the visible one.
    #[allow(dead_code)]
    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }

    /// Retire the displayed request and promote the next queued one.
    ///
    /// Returns the id to dispatch the user's decision against, and whether a
    /// successor took the screen (in which case the overlay must stay open).
    pub fn answer_current(&mut self) -> Option<Answered> {
        let request_id = self.displayed.take()?.request_id().to_string();
        if let Some(next) = self.pending.pop_front() {
            self.displayed = Some(next.into_dialog());
        }
        let has_more = self.displayed.is_some();
        Some(Answered {
            request_id,
            has_more,
        })
    }

    /// Drop the visible prompt and everything behind it — the turn they belong
    /// to is gone, so answering them would resume nothing.
    pub fn clear(&mut self) {
        self.displayed = None;
        self.pending.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(id: &str, tool: &str) -> PermissionRequest {
        PermissionRequest {
            request_id: id.into(),
            tool: tool.into(),
            args: format!("args-for-{id}"),
            target: Some(format!("target-{id}")),
            old_content: Some(format!("old-{id}")),
            new_content: Some(format!("new-{id}")),
            warning: None,
            reason: None,
        }
    }

    /// Two parallel asks: the SECOND must not take the screen from the first.
    #[test]
    fn second_request_does_not_replace_displayed() {
        let mut q = PermissionQueue::new();
        assert_eq!(q.submit(req("A", "shell_execute")), Submission::Displayed);
        assert_eq!(q.submit(req("B", "shell_execute")), Submission::Queued);

        assert_eq!(q.current_request_id(), Some("A"));
        assert_eq!(q.displayed().unwrap().tool_name, "shell_execute");
        assert_eq!(q.displayed().unwrap().tool_args, "args-for-A");
        assert_eq!(q.pending_len(), 1);
    }

    /// SECURITY: the decision must be dispatched against the id of the request
    /// the user was actually shown, never the one that arrived behind it.
    #[test]
    fn answer_dispatches_displayed_id_not_newest() {
        let mut q = PermissionQueue::new();
        q.submit(req("A", "shell_execute"));
        q.submit(req("B", "shell_execute"));

        let answered = q.answer_current().expect("a request was displayed");
        assert_eq!(
            answered.request_id, "A",
            "approving the visible request must answer A, not the request that arrived behind it"
        );
        assert!(answered.has_more, "B is still waiting");
    }

    /// The promoted request brings its own content — no leftovers from A.
    #[test]
    fn next_request_is_displayed_with_its_own_content() {
        let mut q = PermissionQueue::new();
        q.submit(req("A", "shell_execute"));
        q.submit(req("B", "file_write"));

        q.answer_current().unwrap();

        assert_eq!(q.current_request_id(), Some("B"));
        let d = q.displayed().expect("B is now displayed");
        assert_eq!(d.tool_name, "file_write");
        assert_eq!(d.tool_args, "args-for-B");
        assert_eq!(d.target.as_deref(), Some("target-B"));
        assert_eq!(d.diff_old.as_deref(), Some("old-B"));
        assert_eq!(d.diff_new.as_deref(), Some("new-B"));
        assert_eq!(q.pending_len(), 0);
    }

    /// The overlay stays up until the LAST queued ask is answered.
    #[test]
    fn overlay_exits_only_when_queue_drains() {
        let mut q = PermissionQueue::new();
        q.submit(req("A", "shell_execute"));
        q.submit(req("B", "shell_execute"));
        q.submit(req("C", "shell_execute"));

        assert!(q.answer_current().unwrap().has_more);
        assert!(q.is_active());
        assert!(q.answer_current().unwrap().has_more);
        assert!(q.is_active());

        let last = q.answer_current().unwrap();
        assert_eq!(last.request_id, "C");
        assert!(!last.has_more, "queue drained — the overlay may close now");
        assert!(!q.is_active());
        assert_eq!(q.answer_current(), None);
    }

    /// Reconnect replay re-delivers the same id; it must not stack up.
    #[test]
    fn duplicate_request_id_does_not_double_enqueue() {
        let mut q = PermissionQueue::new();
        q.submit(req("A", "shell_execute"));
        assert_eq!(q.submit(req("A", "shell_execute")), Submission::Duplicate);
        assert_eq!(q.pending_len(), 0);

        q.submit(req("B", "shell_execute"));
        assert_eq!(q.submit(req("B", "shell_execute")), Submission::Duplicate);
        assert_eq!(q.pending_len(), 1);

        // Answering A leaves exactly one B, and the queue is then empty.
        assert_eq!(q.answer_current().unwrap().request_id, "A");
        assert_eq!(q.current_request_id(), Some("B"));
        assert!(!q.answer_current().unwrap().has_more);
    }

    /// A cancelled / torn-down turn leaves no orphan dialogs.
    #[test]
    fn clear_drops_displayed_and_pending() {
        let mut q = PermissionQueue::new();
        q.submit(req("A", "shell_execute"));
        q.submit(req("B", "shell_execute"));
        q.submit(req("C", "shell_execute"));

        q.clear();

        assert!(!q.is_active());
        assert_eq!(q.pending_len(), 0);
        assert_eq!(q.current_request_id(), None);
        assert_eq!(q.answer_current(), None);
    }
}
