// Phase 2+: ComponentAction variants and set_focused — wired when focus dispatch is added
#![allow(dead_code)]

pub mod activity;
pub mod agents;
pub mod chat;
pub mod header;
pub mod input;
pub mod measure;
pub mod notify;
pub mod osc8;
pub mod osc52;
pub mod status_bar;
pub mod title;
pub mod task_checklist;
pub mod tasks;
pub mod toast;
pub mod sidebar;

use ratatui::prelude::*;

use crate::event::Event;

/// Action returned by component event handling
#[derive(Debug)]
pub enum ComponentAction {
    /// Event was consumed, stop propagation
    Consumed,
    /// Event was not handled, continue propagation
    Ignored,
    /// Event produced an app-level action
    Emit(AppAction),
}

/// Actions that bubble up from components to the app
#[derive(Debug)]
pub enum AppAction {
    /// Submit user input
    Submit(String),
    /// Quit the application
    Quit,
    /// Toggle sidebar visibility
    ToggleSidebar,
    /// Toggle activity expand
    ToggleExpand,
    /// Toggle thinking box
    ToggleThinking,
    /// Move task to background
    BackgroundTask,
    /// Open command palette
    OpenPalette,
    /// Create new session
    NewSession,
    /// Copy last message to clipboard
    CopyLastMessage,
    /// Show help
    ShowHelp,
    /// Cancel current operation
    Cancel,
    /// Scroll chat
    ScrollChat(ScrollDirection),
    /// Open model picker
    OpenModels,
    /// Open sessions browser
    OpenSessions,
    /// Execute a command
    ExecuteCommand(String, String),
    /// Show a toast message
    Toast(String),
}

#[derive(Debug)]
pub enum ScrollDirection {
    Up(u16),
    Down(u16),
    PageUp,
    PageDown,
    Top,
    Bottom,
    HalfPageUp,
    HalfPageDown,
}

/// The Component trait
pub trait Component {
    fn handle_event(&mut self, event: &Event) -> ComponentAction;
    fn draw(&self, frame: &mut Frame, area: Rect);
    fn set_focused(&mut self, _focused: bool) {}
}
