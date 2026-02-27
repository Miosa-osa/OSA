package app

import "github.com/charmbracelet/bubbles/key"

// KeyMap defines all global keybindings.
type KeyMap struct {
	Submit           key.Binding
	Cancel           key.Binding
	Quit             key.Binding
	QuitEOF          key.Binding
	ToggleExpand     key.Binding
	ToggleBackground key.Binding
	ScrollUp         key.Binding
	ScrollDown       key.Binding
	PageUp           key.Binding
	PageDown         key.Binding
	HistoryPrev      key.Binding
	HistoryNext      key.Binding
	Tab              key.Binding
	Escape           key.Binding
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
		Quit: key.NewBinding(
			key.WithKeys("ctrl+c"),
			key.WithHelp("ctrl+c", "quit"),
		),
		QuitEOF: key.NewBinding(
			key.WithKeys("ctrl+d"),
			key.WithHelp("ctrl+d", "quit"),
		),
		ToggleExpand: key.NewBinding(
			key.WithKeys("ctrl+o"),
			key.WithHelp("ctrl+o", "expand/collapse"),
		),
		ToggleBackground: key.NewBinding(
			key.WithKeys("ctrl+b"),
			key.WithHelp("ctrl+b", "background"),
		),
		ScrollUp: key.NewBinding(
			key.WithKeys("up"),
			key.WithHelp("↑", "scroll up"),
		),
		ScrollDown: key.NewBinding(
			key.WithKeys("down"),
			key.WithHelp("↓", "scroll down"),
		),
		PageUp: key.NewBinding(
			key.WithKeys("pgup"),
			key.WithHelp("pgup", "page up"),
		),
		PageDown: key.NewBinding(
			key.WithKeys("pgdown"),
			key.WithHelp("pgdn", "page down"),
		),
		HistoryPrev: key.NewBinding(
			key.WithKeys("up"),
			key.WithHelp("↑", "previous"),
		),
		HistoryNext: key.NewBinding(
			key.WithKeys("down"),
			key.WithHelp("↓", "next"),
		),
		Tab: key.NewBinding(
			key.WithKeys("tab"),
			key.WithHelp("tab", "autocomplete"),
		),
		Escape: key.NewBinding(
			key.WithKeys("esc"),
			key.WithHelp("esc", "cancel"),
		),
	}
}
