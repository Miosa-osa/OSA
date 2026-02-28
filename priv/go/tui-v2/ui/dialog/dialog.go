// Package dialog provides modal overlay primitives for OSA TUI v2.
//
// The package exposes two distinct systems:
//
//  1. RenderDialog — a stateless helper for simple one-shot modal boxes
//     (used by picker.go, palette.go, plan.go via app.go state machine).
//
//  2. Overlay — a stateful stack for NEW dialogs that need stacking.
//     Dialogs pushed onto the Overlay implement the Dialog interface.
package dialog

import (
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// ──────────────────────────────────────────────────────────────────────────────
// Dialog interface
// ──────────────────────────────────────────────────────────────────────────────

// Dialog is the interface all stackable dialogs must implement.
type Dialog interface {
	// Update handles messages and returns the updated dialog plus any commands.
	Update(msg tea.Msg) (Dialog, tea.Cmd)
	// View returns the rendered inner content (without the outer frame).
	View() string
	// Width returns the desired inner dialog width.
	Width() int
	// Height returns the rendered inner content height.
	Height() int
	// Title returns the dialog title shown in the frame header.
	Title() string
}

// ──────────────────────────────────────────────────────────────────────────────
// Overlay — stacked dialog manager
// ──────────────────────────────────────────────────────────────────────────────

// Overlay manages a stack of Dialog values rendered as centered modals.
// The top of the stack (last pushed) is the active dialog.
type Overlay struct {
	stack []Dialog
	termW int
	termH int
}

// NewOverlay returns an empty Overlay.
func NewOverlay() Overlay {
	return Overlay{}
}

// Push places a new dialog on top of the stack.
func (o *Overlay) Push(d Dialog) {
	o.stack = append(o.stack, d)
}

// Pop removes and returns the top dialog. Returns nil if the stack is empty.
func (o *Overlay) Pop() Dialog {
	if len(o.stack) == 0 {
		return nil
	}
	top := o.stack[len(o.stack)-1]
	o.stack = o.stack[:len(o.stack)-1]
	return top
}

// Clear removes all dialogs from the stack.
func (o *Overlay) Clear() {
	o.stack = o.stack[:0]
}

// IsActive reports whether there is at least one dialog on the stack.
func (o Overlay) IsActive() bool { return len(o.stack) > 0 }

// Top returns the topmost Dialog without removing it. Returns nil if empty.
func (o Overlay) Top() Dialog {
	if len(o.stack) == 0 {
		return nil
	}
	return o.stack[len(o.stack)-1]
}

// SetSize updates the terminal dimensions used for centering.
func (o *Overlay) SetSize(w, h int) {
	o.termW = w
	o.termH = h
}

// Update forwards messages to the topmost dialog. If the dialog's Update
// returns a nil Dialog (meaning it dismissed itself), it is popped from
// the stack automatically.
func (o Overlay) Update(msg tea.Msg) (Overlay, tea.Cmd) {
	if !o.IsActive() {
		return o, nil
	}
	// Copy the stack slice so the value receiver produces a fresh Overlay.
	stack := make([]Dialog, len(o.stack))
	copy(stack, o.stack)
	o.stack = stack

	top := o.stack[len(o.stack)-1]
	updated, cmd := top.Update(msg)
	if updated == nil {
		o.stack = o.stack[:len(o.stack)-1]
	} else {
		o.stack[len(o.stack)-1] = updated
	}
	return o, cmd
}

// View renders behindContent with a faint overlay and places the topmost
// dialog as a centered, bordered modal on top.
func (o Overlay) View(behindContent string) string {
	if !o.IsActive() {
		return behindContent
	}

	// behindContent is kept for the signature; future callers may dim it.
	_ = behindContent

	d := o.Top()

	// Inner content.
	title := lipgloss.NewStyle().
		Foreground(style.Primary).
		Bold(true).
		Render(d.Title())
	inner := title + "\n\n" + d.View()

	// Outer frame.
	boxW := d.Width()
	if boxW > o.termW-4 {
		boxW = o.termW - 4
	}
	if boxW < 20 {
		boxW = 20
	}

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Padding(1, 2).
		Width(boxW).
		Render(inner)

	return lipgloss.Place(o.termW, o.termH,
		lipgloss.Center, lipgloss.Center,
		box,
	)
}

// ──────────────────────────────────────────────────────────────────────────────
// Legacy stateless helper (kept for backward compatibility with existing
// picker.go / palette.go / plan.go flows that go through app.go state machine)
// ──────────────────────────────────────────────────────────────────────────────

// RenderDialog renders a titled, bordered dialog centered in the terminal.
// The inner box is capped at 70 characters wide.
func RenderDialog(title, content string, width, termW, termH int) string {
	boxWidth := width
	if boxWidth > 70 {
		boxWidth = 70
	}
	if boxWidth > termW-4 {
		boxWidth = termW - 4
	}
	if boxWidth < 20 {
		boxWidth = 20
	}

	titleRendered := lipgloss.NewStyle().
		Foreground(style.Primary).
		Bold(true).
		Render(title)

	body := titleRendered + "\n\n" + content

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Padding(1, 2).
		Width(boxWidth).
		Render(body)

	return lipgloss.Place(termW, termH, lipgloss.Center, lipgloss.Center, box)
}
