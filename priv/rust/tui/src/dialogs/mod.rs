// Phase 2+: dialog action variants — some dialog actions not yet dispatched
#![allow(dead_code)]

pub mod command_palette;
pub mod config_editor;
pub mod file_picker;
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
pub mod survey;
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
