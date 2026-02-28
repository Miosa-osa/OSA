package dialog

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// ModelEntry describes a single model available for selection.
type ModelEntry struct {
	Name      string
	Size      string // e.g. "7B", "70B", "Unknown"
	Active    bool   // currently selected model
	Reasoning bool   // supports extended thinking / reasoning
	Recent    bool   // recently used
}

// ModelGroup groups models under a named provider header.
type ModelGroup struct {
	Provider string
	Models   []ModelEntry
}

// flatEntry holds a flattened entry for cursor arithmetic across groups.
type flatEntry struct {
	groupIdx int
	entryIdx int
	model    ModelEntry
}

// ModelsModel is an enhanced model picker with provider grouping, filtering,
// size display, reasoning badges, and a recently-used section.
//
// Emits ModelChoice on selection, ModelCancel on Esc.
type ModelsModel struct {
	groups   []ModelGroup
	flat     []flatEntry // flattened, filtered view
	cursor   int
	filter   string
	viewport viewport.Model

	width, height int
}

// NewModels returns a zero-value ModelsModel.
func NewModels() ModelsModel {
	vp := viewport.New(viewport.WithWidth(60), viewport.WithHeight(20))
	vp.SoftWrap = true
	return ModelsModel{viewport: vp}
}

// SetModels populates the picker with provider groups and rebuilds the flat
// index. Cursor is positioned on the active model.
func (m *ModelsModel) SetModels(groups []ModelGroup) {
	m.groups = groups
	m.filter = ""
	m.rebuildFlat()
	m.cursor = 0
	// Position cursor on active model.
	for i, fe := range m.flat {
		if fe.model.Active {
			m.cursor = i
			break
		}
	}
	m.syncViewport()
}

// SetSize updates terminal dimensions and resizes the viewport.
func (m *ModelsModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	vpW := m.dialogWidth() - 6
	if vpW < 20 {
		vpW = 20
	}
	vpH := h - 12
	if vpH < 5 {
		vpH = 5
	}
	m.viewport.SetWidth(vpW)
	m.viewport.SetHeight(vpH)
	m.syncViewport()
}

func (m ModelsModel) dialogWidth() int {
	dw := m.width - 4
	if dw > 80 {
		dw = 80
	}
	if dw < 50 {
		dw = 50
	}
	return dw
}

// rebuildFlat flattens the groups into a single list, applying the filter.
// Recently-used models are prepended as a synthetic group at the top.
func (m *ModelsModel) rebuildFlat() {
	m.flat = m.flat[:0]

	q := strings.ToLower(m.filter)

	// Recent models come first (synthetic group).
	for gi, g := range m.groups {
		for ei, model := range g.Models {
			if !model.Recent {
				continue
			}
			if q != "" && !matchesModelFilter(model, g.Provider, q) {
				continue
			}
			m.flat = append(m.flat, flatEntry{groupIdx: gi, entryIdx: ei, model: model})
		}
	}

	// Then normal groups.
	for gi, g := range m.groups {
		groupAdded := false
		for ei, model := range g.Models {
			if model.Recent {
				continue // already in recent section
			}
			if q != "" && !matchesModelFilter(model, g.Provider, q) {
				continue
			}
			if !groupAdded {
				// Sentinel entry for group header (entryIdx == -1).
				m.flat = append(m.flat, flatEntry{groupIdx: gi, entryIdx: -1})
				groupAdded = true
			}
			m.flat = append(m.flat, flatEntry{groupIdx: gi, entryIdx: ei, model: model})
		}
	}
}

func matchesModelFilter(model ModelEntry, provider, q string) bool {
	return strings.Contains(strings.ToLower(model.Name), q) ||
		strings.Contains(strings.ToLower(provider), q) ||
		strings.Contains(strings.ToLower(model.Size), q)
}

// syncViewport rebuilds the viewport content from the current flat list.
func (m *ModelsModel) syncViewport() {
	m.viewport.SetContent(m.renderContent())
}

// ──────────────────────────────────────────────────────────────────────────────
// Update
// ──────────────────────────────────────────────────────────────────────────────

// Update handles keyboard input.
//
//	↑/k    → move cursor up (skipping header sentinels)
//	↓/j    → move cursor down
//	enter  → emit ModelChoice for selected model
//	esc    → emit ModelCancel
//	char   → append to filter
//	backspace → remove last filter char
func (m ModelsModel) Update(msg tea.Msg) (ModelsModel, tea.Cmd) {
	kp, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}

	switch kp.Code {
	case tea.KeyUp, 'k':
		m.moveCursor(-1)
		m.syncViewport()
		return m, nil

	case tea.KeyDown, 'j':
		m.moveCursor(1)
		m.syncViewport()
		return m, nil

	case tea.KeyEnter:
		if m.cursor < len(m.flat) {
			fe := m.flat[m.cursor]
			if fe.entryIdx >= 0 {
				provider := m.groups[fe.groupIdx].Provider
				modelName := fe.model.Name
				return m, func() tea.Msg {
					return ModelChoice{Provider: provider, Model: modelName}
				}
			}
		}
		return m, nil

	case tea.KeyEscape:
		return m, func() tea.Msg { return ModelCancel{} }

	case tea.KeyBackspace:
		if len(m.filter) > 0 {
			runes := []rune(m.filter)
			m.filter = string(runes[:len(runes)-1])
			m.rebuildFlat()
			m.cursor = 0
			m.syncViewport()
		}
		return m, nil

	default:
		if kp.Code >= 32 && kp.Code < 127 {
			m.filter += string(rune(kp.Code))
			m.rebuildFlat()
			m.cursor = 0
			m.syncViewport()
		}
		return m, nil
	}
}

// moveCursor advances cursor by delta, skipping header sentinels.
func (m *ModelsModel) moveCursor(delta int) {
	n := len(m.flat)
	if n == 0 {
		return
	}
	// Check whether any selectable entry exists at all.
	hasSelectable := false
	for _, fe := range m.flat {
		if fe.entryIdx >= 0 {
			hasSelectable = true
			break
		}
	}
	if !hasSelectable {
		return
	}
	next := m.cursor + delta
	for i := 0; i < n; i++ {
		if next < 0 {
			next = n - 1
		}
		if next >= n {
			next = 0
		}
		if m.flat[next].entryIdx >= 0 {
			break
		}
		next += delta
	}
	m.cursor = next
}

// ──────────────────────────────────────────────────────────────────────────────
// View
// ──────────────────────────────────────────────────────────────────────────────

// View renders the full models dialog.
func (m ModelsModel) View() string {
	dw := m.dialogWidth()

	var sb strings.Builder

	// Title.
	sb.WriteString(GradientTitle("Select Model"))
	sb.WriteByte('\n')
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')

	// Filter bar.
	filterPrompt := style.DialogHelpKey.Render("Filter: ")
	filterVal := m.filter
	if filterVal == "" {
		filterVal = style.Faint.Render("type to filter...")
	} else {
		filterVal = lipgloss.NewStyle().Foreground(style.Secondary).Render(filterVal)
	}
	total := 0
	for _, g := range m.groups {
		total += len(g.Models)
	}
	count := style.Faint.Render(fmt.Sprintf("  (%d model(s))", total))
	sb.WriteString(filterPrompt + filterVal + count)
	sb.WriteByte('\n')
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')

	// Scrollable model list.
	sb.WriteString(m.viewport.View())
	sb.WriteByte('\n')

	// Help bar.
	helpItems := []HelpItem{
		{Key: "↑↓", Desc: "navigate"},
		{Key: "enter", Desc: "select"},
		{Key: "esc", Desc: "cancel"},
	}
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')
	sb.WriteString(RenderHelpBar(helpItems, dw-6))

	frameStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Padding(1, 2).
		Width(dw)

	termW := m.width
	if termW <= 0 {
		termW = 80
	}
	termH := m.height
	if termH <= 0 {
		termH = 40
	}

	box := frameStyle.Render(sb.String())
	return lipgloss.Place(termW, termH, lipgloss.Center, lipgloss.Center, box)
}

// renderContent builds the full text content for the viewport.
func (m ModelsModel) renderContent() string {
	if len(m.flat) == 0 {
		return style.Faint.Render("  No models found")
	}

	recentHeaderEmitted := false
	var sb strings.Builder
	lastGroupIdx := -2

	for i, fe := range m.flat {
		isCursor := i == m.cursor

		// Handle the recent block header.
		if fe.model.Recent && !recentHeaderEmitted {
			recentHeaderEmitted = true
			header := lipgloss.NewStyle().
				Foreground(style.Warning).Bold(true).
				Render("  Recently Used")
			sb.WriteString(header + "\n")
		}

		// Group header sentinel.
		if fe.entryIdx == -1 {
			if fe.groupIdx != lastGroupIdx {
				lastGroupIdx = fe.groupIdx
				g := m.groups[fe.groupIdx]
				count := 0
				for _, model := range g.Models {
					if !model.Recent {
						count++
					}
				}
				header := lipgloss.NewStyle().
					Foreground(style.Secondary).Bold(true).
					Render(fmt.Sprintf("  %s", g.Provider))
				cntLabel := style.Faint.Render(fmt.Sprintf("  (%d)", count))
				sb.WriteString(header + cntLabel + "\n")
			}
			continue
		}

		sb.WriteString(m.renderModelEntry(fe, isCursor))
		sb.WriteByte('\n')
	}

	return strings.TrimRight(sb.String(), "\n")
}

// renderModelEntry renders a single model row.
func (m ModelsModel) renderModelEntry(fe flatEntry, isCursor bool) string {
	cursor := "    "
	if isCursor {
		cursor = style.PlanSelected.Render("  > ")
	}

	var radio string
	if fe.model.Active {
		radio = style.RadioOn.Render("● ")
	} else {
		radio = style.RadioOff.Render("○ ")
	}

	var name string
	if isCursor {
		name = lipgloss.NewStyle().Foreground(style.Secondary).Bold(true).Render(fe.model.Name)
	} else {
		name = style.Faint.Render(fe.model.Name)
	}

	var badges []string
	if fe.model.Size != "" {
		badges = append(badges, style.Faint.Render(fe.model.Size))
	}
	if fe.model.Reasoning {
		badges = append(badges, lipgloss.NewStyle().Foreground(style.Warning).Render("⚡reasoning"))
	}
	if fe.model.Recent {
		badges = append(badges, lipgloss.NewStyle().Foreground(style.Muted).Render("recent"))
	}
	if fe.model.Active {
		badges = append(badges, lipgloss.NewStyle().Foreground(style.Success).Render("active"))
	}

	var suffix string
	if len(badges) > 0 {
		suffix = "  " + strings.Join(badges, "  ")
	}

	return cursor + radio + name + suffix
}
