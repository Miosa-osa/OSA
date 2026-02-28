// Package completions provides a command/file completions popup.
package completions

import "charm.land/bubbles/v2/key"

// KeyMap defines keybindings for the completions popup.
type KeyMap struct {
	Up         key.Binding // move selection up
	Down       key.Binding // move selection down
	Select     key.Binding // accept selected item (closes popup)
	Dismiss    key.Binding // close popup without accepting
	UpInsert   key.Binding // shift+up: accept and keep popup open
	DownInsert key.Binding // shift+down: accept and keep popup open
}

// DefaultKeyMap returns the standard key bindings for the completions popup.
func DefaultKeyMap() KeyMap {
	return KeyMap{
		Up:         key.NewBinding(key.WithKeys("up")),
		Down:       key.NewBinding(key.WithKeys("down")),
		Select:     key.NewBinding(key.WithKeys("enter", "tab")),
		Dismiss:    key.NewBinding(key.WithKeys("esc")),
		UpInsert:   key.NewBinding(key.WithKeys("shift+up")),
		DownInsert: key.NewBinding(key.WithKeys("shift+down")),
	}
}
