// Phase 3: Centralized keymap — wire when splitting update.rs key handlers
#![allow(dead_code)]

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

/// Key binding definition
pub struct KeyBinding {
    pub code: KeyCode,
    pub modifiers: KeyModifiers,
    pub help: &'static str,
}

impl KeyBinding {
    pub const fn new(code: KeyCode, modifiers: KeyModifiers, help: &'static str) -> Self {
        Self {
            code,
            modifiers,
            help,
        }
    }

    pub fn matches(&self, event: &KeyEvent) -> bool {
        event.code == self.code && event.modifiers.contains(self.modifiers)
    }
}

/// All key bindings — 22 bindings matching Go keymap
pub struct KeyMap {
    pub submit: KeyBinding,
    pub cancel: KeyBinding,
    pub quit_eof: KeyBinding,
    pub escape: KeyBinding,
    pub help: KeyBinding,
    pub page_up: KeyBinding,
    pub page_down: KeyBinding,
    pub scroll_top: KeyBinding,
    pub scroll_bottom: KeyBinding,
    pub scroll_up: KeyBinding,
    pub scroll_down: KeyBinding,
    pub half_page_up: KeyBinding,
    pub half_page_down: KeyBinding,
    pub toggle_expand: KeyBinding,
    pub toggle_thinking: KeyBinding,
    pub toggle_background: KeyBinding,
    pub toggle_sidebar: KeyBinding,
    pub tab: KeyBinding,
    pub clear_input: KeyBinding,
    pub new_session: KeyBinding,
    pub palette: KeyBinding,
    pub copy_message: KeyBinding,
    pub voice_toggle: KeyBinding,
    pub voice_hands_free: KeyBinding,
}

impl Default for KeyMap {
    fn default() -> Self {
        Self {
            submit: KeyBinding::new(KeyCode::Enter, KeyModifiers::NONE, "submit"),
            cancel: KeyBinding::new(KeyCode::Char('c'), KeyModifiers::CONTROL, "cancel/quit"),
            quit_eof: KeyBinding::new(KeyCode::Char('d'), KeyModifiers::CONTROL, "quit"),
            escape: KeyBinding::new(KeyCode::Esc, KeyModifiers::NONE, "cancel"),
            help: KeyBinding::new(KeyCode::F(1), KeyModifiers::NONE, "help"),
            page_up: KeyBinding::new(KeyCode::PageUp, KeyModifiers::NONE, "page up"),
            page_down: KeyBinding::new(KeyCode::PageDown, KeyModifiers::NONE, "page down"),
            scroll_top: KeyBinding::new(KeyCode::Home, KeyModifiers::NONE, "scroll top"),
            scroll_bottom: KeyBinding::new(KeyCode::End, KeyModifiers::NONE, "scroll bottom"),
            scroll_up: KeyBinding::new(KeyCode::Char('k'), KeyModifiers::NONE, "scroll up"),
            scroll_down: KeyBinding::new(KeyCode::Char('j'), KeyModifiers::NONE, "scroll down"),
            half_page_up: KeyBinding::new(KeyCode::Char('u'), KeyModifiers::NONE, "half page up"),
            half_page_down: KeyBinding::new(
                KeyCode::Char('d'),
                KeyModifiers::NONE,
                "half page down",
            ),
            toggle_expand: KeyBinding::new(
                KeyCode::Char('o'),
                KeyModifiers::CONTROL,
                "expand/collapse",
            ),
            toggle_thinking: KeyBinding::new(
                KeyCode::Char('t'),
                KeyModifiers::CONTROL,
                "toggle thinking",
            ),
            toggle_background: KeyBinding::new(
                KeyCode::Char('b'),
                KeyModifiers::CONTROL,
                "background task",
            ),
            toggle_sidebar: KeyBinding::new(
                KeyCode::Char('l'),
                KeyModifiers::CONTROL,
                "toggle sidebar",
            ),
            tab: KeyBinding::new(KeyCode::Tab, KeyModifiers::NONE, "autocomplete"),
            clear_input: KeyBinding::new(KeyCode::Char('u'), KeyModifiers::CONTROL, "clear input"),
            new_session: KeyBinding::new(KeyCode::Char('n'), KeyModifiers::CONTROL, "new session"),
            palette: KeyBinding::new(KeyCode::Char('k'), KeyModifiers::CONTROL, "command palette"),
            copy_message: KeyBinding::new(
                KeyCode::Char('y'),
                KeyModifiers::NONE,
                "copy last message",
            ),
            voice_toggle: KeyBinding::new(KeyCode::Char('v'), KeyModifiers::ALT, "voice input"),
            voice_hands_free: KeyBinding::new(
                KeyCode::F(9),
                KeyModifiers::NONE,
                "hands-free voice",
            ),
        }
    }
}
