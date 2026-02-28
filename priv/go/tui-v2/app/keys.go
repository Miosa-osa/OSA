package app

import "charm.land/bubbles/v2/key"

// KeyMap defines all global keybindings.
type KeyMap struct {
	// Global
	Submit  key.Binding
	Cancel  key.Binding
	QuitEOF key.Binding
	Escape  key.Binding
	Help    key.Binding

	// Navigation
	PageUp       key.Binding
	PageDown     key.Binding
	ScrollTop    key.Binding
	ScrollBottom key.Binding
	ScrollUp     key.Binding // k
	ScrollDown   key.Binding // j
	HalfPageUp   key.Binding // u
	HalfPageDown key.Binding // d

	// Toggles
	ToggleExpand     key.Binding
	ToggleThinking   key.Binding
	ToggleBackground key.Binding
	ToggleSidebar    key.Binding

	// Editor
	Tab        key.Binding
	ClearInput key.Binding

	// Commands
	NewSession key.Binding
	Palette    key.Binding

	// Copy
	CopyMessage key.Binding
}

// DefaultKeyMap returns the default keybindings.
func DefaultKeyMap() KeyMap {
	return KeyMap{
		Submit: key.NewBinding(
			key.WithKeys("enter"),
			key.WithHelp("enter", "submit"),
		),
		Cancel: key.NewBinding(
			key.WithKeys("ctrl+c"),
			key.WithHelp("ctrl+c", "cancel/quit"),
		),
		QuitEOF: key.NewBinding(
			key.WithKeys("ctrl+d"),
			key.WithHelp("ctrl+d", "quit"),
		),
		Escape: key.NewBinding(
			key.WithKeys("esc"),
			key.WithHelp("esc", "cancel"),
		),
		Help: key.NewBinding(
			key.WithKeys("f1"),
			key.WithHelp("F1", "help"),
		),
		PageUp: key.NewBinding(
			key.WithKeys("pgup"),
			key.WithHelp("pgup", "page up"),
		),
		PageDown: key.NewBinding(
			key.WithKeys("pgdown"),
			key.WithHelp("pgdn", "page down"),
		),
		ScrollTop: key.NewBinding(
			key.WithKeys("home"),
			key.WithHelp("home", "scroll top"),
		),
		ScrollBottom: key.NewBinding(
			key.WithKeys("end"),
			key.WithHelp("end", "scroll bottom"),
		),
		ScrollUp: key.NewBinding(
			key.WithKeys("k"),
			key.WithHelp("k", "scroll up"),
		),
		ScrollDown: key.NewBinding(
			key.WithKeys("j"),
			key.WithHelp("j", "scroll down"),
		),
		HalfPageUp: key.NewBinding(
			key.WithKeys("u"),
			key.WithHelp("u", "half page up"),
		),
		HalfPageDown: key.NewBinding(
			key.WithKeys("d"),
			key.WithHelp("d", "half page down"),
		),
		ToggleExpand: key.NewBinding(
			key.WithKeys("ctrl+o"),
			key.WithHelp("ctrl+o", "expand/collapse"),
		),
		ToggleThinking: key.NewBinding(
			key.WithKeys("ctrl+t"),
			key.WithHelp("ctrl+t", "toggle thinking"),
		),
		ToggleBackground: key.NewBinding(
			key.WithKeys("ctrl+b"),
			key.WithHelp("ctrl+b", "background"),
		),
		ToggleSidebar: key.NewBinding(
			key.WithKeys("ctrl+l"),
			key.WithHelp("ctrl+l", "toggle sidebar"),
		),
		Tab: key.NewBinding(
			key.WithKeys("tab"),
			key.WithHelp("tab", "autocomplete"),
		),
		ClearInput: key.NewBinding(
			key.WithKeys("ctrl+u"),
			key.WithHelp("ctrl+u", "clear input"),
		),
		NewSession: key.NewBinding(
			key.WithKeys("ctrl+n"),
			key.WithHelp("ctrl+n", "new session"),
		),
		Palette: key.NewBinding(
			key.WithKeys("ctrl+k"),
			key.WithHelp("ctrl+k", "command palette"),
		),
		CopyMessage: key.NewBinding(
			key.WithKeys("y", "c"),
			key.WithHelp("y/c", "copy message"),
		),
	}
}
