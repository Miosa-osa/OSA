// Package common — keybind helpers shared across OSA TUI v2 components.
package common

import (
	"strings"

	"charm.land/bubbles/v2/key"
	tea "charm.land/bubbletea/v2"
	"github.com/miosa/osa-tui/style"
)

// KeyHelp renders a formatted key-binding help line for the status bar or
// contextual help overlay. Each binding is rendered as:
//
//	[key]  description
//
// Bindings whose Enabled() is false are omitted.
func KeyHelp(bindings ...key.Binding) string {
	var parts []string
	for _, b := range bindings {
		if !b.Enabled() {
			continue
		}
		keys := strings.Join(b.Keys(), "/")
		keyStr := style.HelpKey.Render("[" + keys + "]")
		helpStr := style.HelpDesc.Render(" " + b.Help().Desc)
		parts = append(parts, keyStr+helpStr)
	}
	return strings.Join(parts, style.HelpSeparator.Render("  ·  "))
}

// IsModKey reports whether the key press event has any modifier held
// (ctrl, alt/meta, or shift with a non-shift key code).
func IsModKey(k tea.KeyPressMsg) bool {
	return k.Mod&(tea.ModCtrl|tea.ModAlt|tea.ModMeta|tea.ModShift) != 0
}

// ShortcutLabel returns a human-readable label for the first key of a binding,
// e.g. "ctrl+c", "enter", "?". Returns an empty string if the binding has no keys.
func ShortcutLabel(b key.Binding) string {
	keys := b.Keys()
	if len(keys) == 0 {
		return ""
	}
	return keys[0]
}
