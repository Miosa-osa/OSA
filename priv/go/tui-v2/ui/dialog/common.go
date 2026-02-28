package dialog

import (
	"strings"
	"unicode/utf8"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// RenderContext provides terminal dimensions for dialog chrome sizing.
type RenderContext struct {
	TermWidth  int
	TermHeight int
}

// GradientTitle renders a dialog title with the theme gradient coloring.
func GradientTitle(title string) string {
	return style.ApplyBoldForegroundGrad(title)
}

// ButtonDef defines a single button in a dialog button group.
type ButtonDef struct {
	Label     string
	Shortcut  string // e.g. "y", "n", "enter"
	Active    bool
	Danger    bool // red styling for destructive actions
	Underline int  // index of char to underline as hotkey (-1 for none)
}

// RenderButtons renders a horizontal button group centered within width.
// Active button uses ButtonActive style; Danger uses ButtonDanger; others
// use ButtonInactive.
func RenderButtons(buttons []ButtonDef, width int) string {
	var parts []string
	for _, btn := range buttons {
		label := btn.Label
		if btn.Underline >= 0 && btn.Underline < utf8.RuneCountInString(label) {
			runes := []rune(label)
			label = string(runes[:btn.Underline]) +
				lipgloss.NewStyle().Underline(true).Render(string(runes[btn.Underline:btn.Underline+1])) +
				string(runes[btn.Underline+1:])
		}

		var rendered string
		switch {
		case btn.Active && btn.Danger:
			rendered = style.ButtonDanger.Render(label)
		case btn.Active:
			rendered = style.ButtonActive.Render(label)
		default:
			rendered = style.ButtonInactive.Render(label)
		}
		parts = append(parts, rendered)
	}

	row := strings.Join(parts, "  ")
	rowWidth := lipgloss.Width(row)
	if width > rowWidth {
		pad := (width - rowWidth) / 2
		row = strings.Repeat(" ", pad) + row
	}
	return row
}

// HelpItem is a single key+description pair shown in a help bar.
type HelpItem struct {
	Key  string
	Desc string
}

// RenderHelpBar renders a row of keyboard shortcuts at dialog bottom.
// Items are separated by "  ·  " and the whole row is muted.
func RenderHelpBar(items []HelpItem, width int) string {
	if len(items) == 0 {
		return ""
	}

	var parts []string
	for _, item := range items {
		k := style.DialogHelpKey.Render(item.Key)
		d := style.DialogHelp.Render(" " + item.Desc)
		parts = append(parts, k+d)
	}

	sep := style.DialogHelp.Render("  ·  ")
	bar := strings.Join(parts, sep)

	// Center if there's room.
	barWidth := lipgloss.Width(bar)
	if width > barWidth {
		pad := (width - barWidth) / 2
		bar = strings.Repeat(" ", pad) + bar
	}
	return bar
}

// InputCursor is a minimal single-line text editor with a visible cursor.
// It is used for inline rename inputs and filter boxes inside dialogs.
type InputCursor struct {
	Value   string
	Cursor  int // byte offset into Value
	Focused bool
	Width   int
}

// View renders the input with a blinking cursor character at the insertion
// point. When unfocused, the raw value is shown without a cursor.
func (ic InputCursor) View() string {
	runes := []rune(ic.Value)
	n := len(runes)

	// Clamp cursor.
	cur := ic.Cursor
	if cur < 0 {
		cur = 0
	}
	if cur > n {
		cur = n
	}

	left := string(runes[:cur])
	right := string(runes[cur:])

	var cursor string
	if ic.Focused {
		if len(right) > 0 {
			cursor = style.ButtonActive.Render(string([]rune(right)[:1]))
			right = string([]rune(right)[1:])
		} else {
			cursor = style.ButtonActive.Render(" ")
		}
	} else {
		if len(right) > 0 {
			cursor = string([]rune(right)[:1])
			right = string([]rune(right)[1:])
		}
	}

	line := left + cursor + right

	st := lipgloss.NewStyle().Foreground(style.Secondary)
	if ic.Width > 0 {
		st = st.Width(ic.Width)
	}
	return st.Render(line)
}

// Insert inserts a rune at the current cursor position and advances the cursor.
func (ic *InputCursor) Insert(ch rune) {
	runes := []rune(ic.Value)
	cur := ic.Cursor
	if cur < 0 {
		cur = 0
	}
	if cur > len(runes) {
		cur = len(runes)
	}
	runes = append(runes[:cur], append([]rune{ch}, runes[cur:]...)...)
	ic.Value = string(runes)
	ic.Cursor = cur + 1
}

// Backspace deletes the rune immediately before the cursor.
func (ic *InputCursor) Backspace() {
	runes := []rune(ic.Value)
	cur := ic.Cursor
	if cur <= 0 || len(runes) == 0 {
		return
	}
	runes = append(runes[:cur-1], runes[cur:]...)
	ic.Value = string(runes)
	ic.Cursor = cur - 1
}

// SetValue replaces the current value and moves the cursor to the end.
func (ic *InputCursor) SetValue(s string) {
	ic.Value = s
	ic.Cursor = utf8.RuneCountInString(s)
}
