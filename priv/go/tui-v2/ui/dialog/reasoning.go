package dialog

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// ReasoningLevel controls the depth of extended thinking sent to the model.
type ReasoningLevel int

const (
	ReasoningOff    ReasoningLevel = iota // No extended thinking
	ReasoningLow                          // Brief reasoning (default)
	ReasoningMedium                       // Moderate reasoning depth
	ReasoningHigh                         // Maximum reasoning depth
)

func (r ReasoningLevel) String() string {
	switch r {
	case ReasoningOff:
		return "Off"
	case ReasoningLow:
		return "Low"
	case ReasoningMedium:
		return "Medium"
	case ReasoningHigh:
		return "High"
	default:
		return "Unknown"
	}
}

// ReasoningChoice is emitted when the user selects a level.
type ReasoningChoice struct {
	Level ReasoningLevel
}

// ReasoningCancel is emitted when the user dismisses without selecting.
type ReasoningCancel struct{}

// reasoningEntry describes a single row in the selector.
type reasoningEntry struct {
	level ReasoningLevel
	desc  string
}

var reasoningEntries = []reasoningEntry{
	{ReasoningOff, "No extended thinking"},
	{ReasoningLow, "Brief reasoning (default)"},
	{ReasoningMedium, "Moderate reasoning depth"},
	{ReasoningHigh, "Maximum reasoning depth"},
}

// ──────────────────────────────────────────────────────────────────────────────
// ReasoningModel — standalone (non-stacking) usage
// ──────────────────────────────────────────────────────────────────────────────

// ReasoningModel is a self-contained Bubbletea model for selecting a reasoning
// level. It can be used directly via app state (like PickerModel) or wrapped
// in an Overlay-compatible adapter (see ReasoningDialog below).
type ReasoningModel struct {
	cursor  int
	current ReasoningLevel // pre-selected level shown at open time
	active  bool
	width   int
}

// NewReasoning returns a ReasoningModel with cursor on ReasoningLow.
func NewReasoning() ReasoningModel {
	return ReasoningModel{
		cursor:  int(ReasoningLow),
		current: ReasoningLow,
	}
}

// Open activates the model with the given current level and terminal width.
func (m *ReasoningModel) Open(current ReasoningLevel, width int) {
	m.current = current
	m.cursor = int(current)
	m.active = true
	m.width = width
}

// Close deactivates the model.
func (m *ReasoningModel) Close() { m.active = false }

// IsActive reports whether the reasoning picker is visible.
func (m ReasoningModel) IsActive() bool { return m.active }

// SetWidth constrains rendering to the given terminal width.
func (m *ReasoningModel) SetWidth(w int) { m.width = w }

// Update handles keyboard input. Key events arrive as tea.KeyPressMsg in v2.
func (m ReasoningModel) Update(msg tea.Msg) (ReasoningModel, tea.Cmd) {
	if !m.active {
		return m, nil
	}

	kp, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}

	switch kp.Code {
	case tea.KeyUp:
		if m.cursor > 0 {
			m.cursor--
		} else {
			m.cursor = len(reasoningEntries) - 1
		}

	case tea.KeyDown:
		if m.cursor < len(reasoningEntries)-1 {
			m.cursor++
		} else {
			m.cursor = 0
		}

	case tea.KeyEnter:
		chosen := ReasoningLevel(m.cursor)
		m.active = false
		return m, func() tea.Msg { return ReasoningChoice{Level: chosen} }

	case tea.KeyEscape:
		m.active = false
		return m, func() tea.Msg { return ReasoningCancel{} }
	}

	return m, nil
}

// View renders the reasoning level selector. Returns an empty string when
// inactive.
func (m ReasoningModel) View() string {
	if !m.active {
		return ""
	}
	return renderReasoningContent(m.cursor, m.current)
}

// ──────────────────────────────────────────────────────────────────────────────
// ReasoningDialog — Overlay-compatible wrapper implementing Dialog interface
// ──────────────────────────────────────────────────────────────────────────────

// ReasoningDialog wraps ReasoningModel so it satisfies the Dialog interface
// and can be pushed onto an Overlay stack.
type ReasoningDialog struct {
	m ReasoningModel
}

// NewReasoningDialog returns a ReasoningDialog ready to be pushed onto an
// Overlay, with the given current level pre-selected.
func NewReasoningDialog(current ReasoningLevel) *ReasoningDialog {
	m := NewReasoning()
	m.cursor = int(current)
	m.current = current
	m.active = true
	return &ReasoningDialog{m: m}
}

// Update implements Dialog. Returns nil when the dialog has dismissed itself
// so the Overlay can pop it automatically.
func (d *ReasoningDialog) Update(msg tea.Msg) (Dialog, tea.Cmd) {
	updated, cmd := d.m.Update(msg)
	d.m = updated
	if !d.m.active {
		// Signal to Overlay.Update that this dialog is done.
		return nil, cmd
	}
	return d, cmd
}

// View implements Dialog.
func (d *ReasoningDialog) View() string {
	return renderReasoningContent(d.m.cursor, d.m.current)
}

// Width implements Dialog — 44 columns is enough for all labels.
func (d *ReasoningDialog) Width() int { return 44 }

// Height implements Dialog.
func (d *ReasoningDialog) Height() int { return len(reasoningEntries) + 1 }

// Title implements Dialog.
func (d *ReasoningDialog) Title() string { return "Reasoning Level" }

// ──────────────────────────────────────────────────────────────────────────────
// Shared rendering
// ──────────────────────────────────────────────────────────────────────────────

// renderReasoningContent builds the list body shared by both model variants.
func renderReasoningContent(cursor int, current ReasoningLevel) string {
	var sb strings.Builder

	hint := lipgloss.NewStyle().Foreground(style.Muted).Render("↑↓ navigate · Enter select · Esc cancel")
	sb.WriteString(hint + "\n\n")

	for i, entry := range reasoningEntries {
		isCursor := i == cursor
		isCurrent := entry.level == current

		var marker string
		if isCursor {
			marker = style.PlanSelected.Render("▸ ")
		} else {
			marker = "  "
		}

		var levelStr string
		if isCursor {
			levelStr = style.PlanSelected.Render(entry.level.String())
		} else if isCurrent {
			levelStr = lipgloss.NewStyle().Foreground(style.Secondary).Render(entry.level.String())
		} else {
			levelStr = style.Faint.Render(entry.level.String())
		}

		// Pad the level label to a fixed width so descriptions align.
		padded := padRight(entry.level.String(), 8)
		if isCursor {
			padded = style.PlanSelected.Render(padded)
		} else if isCurrent {
			padded = lipgloss.NewStyle().Foreground(style.Secondary).Render(padded)
		} else {
			padded = style.Faint.Render(padded)
		}
		// Override with the styled levelStr for cursor to get bold.
		if isCursor {
			padded = levelStr + strings.Repeat(" ", max(0, 8-len(entry.level.String())))
		}

		var desc string
		if isCursor {
			desc = lipgloss.NewStyle().Foreground(style.Muted).Render(entry.desc)
		} else {
			desc = style.Faint.Render(entry.desc)
		}

		// Active indicator badge.
		var badge string
		if isCurrent && !isCursor {
			badge = lipgloss.NewStyle().Foreground(style.Success).Render(" ●")
		}

		sb.WriteString(marker + padded + "  " + desc + badge)
		if i < len(reasoningEntries)-1 {
			sb.WriteByte('\n')
		}
	}

	return sb.String()
}

// padRight pads s with spaces to at least n runes.
func padRight(s string, n int) string {
	if len(s) >= n {
		return s
	}
	return s + strings.Repeat(" ", n-len(s))
}

// max returns the larger of two ints (Go 1.21 built-in, kept for clarity).
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
