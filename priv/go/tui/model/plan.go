package model

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/miosa/osa-tui/markdown"
	"github.com/miosa/osa-tui/style"
)

// PlanDecision is emitted when the user confirms a plan action.
type PlanDecision struct {
	Decision string // "approve", "reject", or "edit"
}

var planOptions = []string{"Approve", "Reject", "Edit"}

// PlanModel renders a plan review panel with approve/reject/edit selector.
// It is inactive until SetPlan is called.
type PlanModel struct {
	content  string
	active   bool
	selected int // 0=Approve, 1=Reject, 2=Edit
	width    int
}

// NewPlan returns a zero-value PlanModel ready to receive a plan.
func NewPlan() PlanModel {
	return PlanModel{}
}

// SetPlan activates the model with the given markdown plan content.
func (m *PlanModel) SetPlan(content string) {
	m.content = content
	m.selected = 0
	m.active = true
}

// Clear deactivates the model and clears the plan content.
func (m *PlanModel) Clear() {
	m.active = false
	m.content = ""
	m.selected = 0
}

// IsActive reports whether the plan panel is currently visible.
func (m *PlanModel) IsActive() bool {
	return m.active
}

// Selected returns the lowercase name of the currently selected option.
func (m *PlanModel) Selected() string {
	return strings.ToLower(planOptions[m.selected])
}

// SetWidth constrains the plan rendering to the given terminal width.
func (m *PlanModel) SetWidth(w int) {
	m.width = w
}

// Init satisfies tea.Model.
func (m PlanModel) Init() tea.Cmd {
	return nil
}

// Update handles keyboard input when the plan panel is active.
// It satisfies tea.Model so callers can type-assert the return value.
func (m PlanModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if !m.active {
		return m, nil
	}

	keyMsg, ok := msg.(tea.KeyMsg)
	if !ok {
		return m, nil
	}

	switch keyMsg.Type {
	case tea.KeyLeft:
		if m.selected > 0 {
			m.selected--
		} else {
			m.selected = len(planOptions) - 1
		}

	case tea.KeyRight:
		if m.selected < len(planOptions)-1 {
			m.selected++
		} else {
			m.selected = 0
		}

	case tea.KeyEnter:
		decision := m.Selected()
		m.Clear()
		return m, func() tea.Msg { return PlanDecision{Decision: decision} }

	case tea.KeyEsc:
		m.Clear()
		return m, func() tea.Msg { return PlanDecision{Decision: "reject"} }
	}

	return m, nil
}

// View renders the plan panel. Returns an empty string when inactive.
func (m PlanModel) View() string {
	if !m.active {
		return ""
	}

	// Render plan content with a width-constrained markdown renderer.
	// Account for PlanBorder's horizontal padding (2 each side) + border (1 each side).
	innerWidth := m.width - 6
	if innerWidth < 20 {
		innerWidth = 80
	}
	rendered := markdown.RenderWidth(m.content, innerWidth)

	// Build selector line.
	selector := buildPlanSelector(m.selected)

	body := rendered + "\n\n" + selector

	// Apply the bordered box. Width constraints are applied via SetWidth on the
	// style rather than on PlanBorder directly so we don't mutate package state.
	boxStyle := style.PlanBorder
	if m.width > 0 {
		boxStyle = boxStyle.Width(m.width - 2)
	}

	return boxStyle.Render(body)
}

// buildPlanSelector returns the option line, e.g.:
//
//	> Approve  ○ Reject  ○ Edit
func buildPlanSelector(selected int) string {
	var parts []string
	for i, opt := range planOptions {
		if i == selected {
			parts = append(parts, style.PlanSelected.Render("> "+opt))
		} else {
			parts = append(parts, style.PlanUnselected.Render("○ "+opt))
		}
	}
	return strings.Join(parts, "  ")
}
