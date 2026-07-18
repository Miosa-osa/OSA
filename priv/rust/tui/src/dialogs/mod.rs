// Phase 2+: dialog action variants — some dialog actions not yet dispatched
#![allow(dead_code)]

pub mod command_palette;
pub mod config_editor;
pub mod context_breakdown;
pub mod file_picker;
pub mod keybindings_viewer;
pub mod mcp_approval;
pub mod model_picker;
pub mod onboarding;
pub mod overdrive_confirm;
pub mod permissions;
pub mod picker;
pub mod plan_review;
pub mod quit_confirm;
pub mod reasoning;
pub mod rewind;
pub mod sessions;
pub mod status_dashboard;
pub mod survey;
pub mod theme_picker;
pub mod tools_browser;
pub mod transcript_viewer;
pub mod trust;

/// Actions produced by dialog event handling that bubble up to the app layer.
#[derive(Debug, Clone)]
pub enum DialogAction {
    /// Dialog was dismissed without a meaningful selection.
    Dismissed,
    /// User confirmed the quit dialog.
    QuitConfirmed,
    /// User selected and executed a command from the palette.
    PaletteExecute(String),
    /// User approved the plan.
    PlanApprove,
    /// User rejected the plan.
    PlanReject,
    /// User wants to edit the plan.
    PlanEdit,
    /// User granted the tool permission for this invocation.
    PermissionAllow,
    /// User granted the tool permission for the remainder of the session.
    PermissionAllowSession,
    /// User granted the tool permission and asked the backend to persist an
    /// always-allow rule for this tool/command.
    PermissionAllowAlways,
    /// User typed a free-text clarification/instruction instead of a binary
    /// allow/deny; the string is steered back to the agent as a message.
    PermissionClarify(String),
    /// User denied the tool permission.
    PermissionDeny,
    /// User selected an item from a generic picker.
    PickerSelect { index: usize, label: String },
    /// User cancelled a generic picker without selecting.
    PickerCancel,
    /// User closed the /config editor.
    ConfigClose,
    /// User committed a value in the /config editor (field label + new value).
    ConfigSetValue { field: String, value: String },
}

/// Clamp a stored scroll offset so `cursor` always falls inside the `viewport`
/// rows starting at the returned offset. Dialogs call this at render time with
/// the REAL measured list height, guaranteeing the selected row is visible even
/// when the stored offset was computed against a stale height (e.g. right
/// after a terminal resize, or before the first frame measured the viewport).
pub(crate) fn clamp_scroll_to_cursor(stored: usize, cursor: usize, viewport: usize) -> usize {
    let mut s = stored.min(cursor);
    if viewport > 0 && cursor >= s + viewport {
        s = cursor + 1 - viewport;
    }
    s
}
