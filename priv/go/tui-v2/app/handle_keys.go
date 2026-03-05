package app

import (
	"strings"

	"charm.land/bubbles/v2/key"
	tea "charm.land/bubbletea/v2"

	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/ui/clipboard"
	"github.com/miosa/osa-tui/ui/dialog"
	"github.com/miosa/osa-tui/ui/toast"
)

// -- Key handling -------------------------------------------------------------
// -- Key handling -------------------------------------------------------------

// updateSearch re-runs the search against current chat items and jumps to the first match.
func (m *Model) updateSearch() {
	m.searchMatches = m.chat.SearchItems(m.searchQuery)
	m.searchCursor = 0
	if len(m.searchMatches) > 0 {
		m.chat.ScrollToItemIndex(m.searchMatches[0])
	}
}

func (m Model) handleKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	// Search mode intercepts all keys before the state switch.
	if m.searchMode {
		return m.handleSearchKey(k)
	}

	switch m.state {
	case StateIdle:
		return m.handleIdleKey(k)
	case StateProcessing:
		return m.handleProcessingKey(k)
	case StatePlanReview:
		return m.handlePlanKey(k)
	case StateModelPicker:
		return m.handlePickerKey(k)
	case StatePalette:
		return m.handlePaletteKey(k)
	case StatePermissions:
		return m.handlePermissionsKey(k)
	case StateQuit:
		return m.handleQuitKey(k)
	case StateSessions:
		return m.handleSessionsKey(k)
	case StateModels:
		return m.handleModelsKey(k)
	case StateOnboarding:
		var cmd tea.Cmd
		m.onboarding, cmd = m.onboarding.Update(k)
		return m, cmd
	case StateBanner:
		m.state = StateIdle
		return m, m.input.Focus()
	}
	return m, nil
}

// handleSearchKey handles all key events when search mode is active.
func (m Model) handleSearchKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	switch {
	case key.Matches[tea.KeyPressMsg](k, m.keys.Search),
		key.Matches[tea.KeyPressMsg](k, m.keys.Escape):
		// Close search
		m.searchMode = false
		m.searchQuery = ""
		m.searchMatches = nil
		m.searchCursor = 0
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.Submit):
		// Close search on Enter — clear all search state
		m.searchMode = false
		m.searchQuery = ""
		m.searchMatches = nil
		m.searchCursor = 0
		return m, nil

	case k.Code == tea.KeyBackspace:
		if len(m.searchQuery) > 0 {
			// Remove last rune (handle multi-byte)
			runes := []rune(m.searchQuery)
			m.searchQuery = string(runes[:len(runes)-1])
			m.updateSearch()
		}
		return m, nil
	}

	// n / N — navigate matches only when there are results; otherwise fall
	// through so the character is appended to the search query normally.
	if k.Text == "n" && len(m.searchMatches) > 0 {
		m.searchCursor = (m.searchCursor + 1) % len(m.searchMatches)
		m.chat.ScrollToItemIndex(m.searchMatches[m.searchCursor])
		return m, nil
	}
	if k.Text == "N" && len(m.searchMatches) > 0 {
		m.searchCursor = (m.searchCursor - 1 + len(m.searchMatches)) % len(m.searchMatches)
		m.chat.ScrollToItemIndex(m.searchMatches[m.searchCursor])
		return m, nil
	}

	// Printable character — append to query
	if k.Text != "" && !strings.ContainsRune(k.Text, '\x00') {
		m.searchQuery += k.Text
		m.updateSearch()
	}

	return m, nil
}

func (m Model) handleIdleKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	// When the completions popup is open, route Enter/Escape/Tab to the
	// input so the popup can handle selection and dismissal instead of
	// the app-level bindings stealing them.
	if m.input.CompletionsVisible() {
		if key.Matches[tea.KeyPressMsg](k, m.keys.Submit) ||
			key.Matches[tea.KeyPressMsg](k, m.keys.Escape) {
			var cmd tea.Cmd
			m.input, cmd = m.input.Update(k)
			return m, cmd
		}
	}

	switch {
	case key.Matches[tea.KeyPressMsg](k, m.keys.Escape):
		m.input.Reset()
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.Cancel):
		if m.input.Value() == "" {
			m.quit = dialog.NewQuit()
			m.quit.SetWidth(m.width)
			m.state = StateQuit
			m.input.Blur()
			return m, nil
		}
		m.input.Reset()
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.QuitEOF):
		if m.input.Value() == "" {
			m.closeSSE()
			return m, tea.Quit
		}

	case key.Matches[tea.KeyPressMsg](k, m.keys.Submit):
		text := strings.TrimSpace(m.input.Value())
		if text == "" {
			return m, nil
		}
		m.input.Submit(text)
		return m.submitInput(text)

	case key.Matches[tea.KeyPressMsg](k, m.keys.Help):
		m.chat.AddSystemMessage(m.dynamicHelpText())
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.NewSession):
		return m, m.createSession()

	case key.Matches[tea.KeyPressMsg](k, m.keys.ToggleSidebar):
		return m.Update(msg.ToggleSidebar{})

	case key.Matches[tea.KeyPressMsg](k, m.keys.ScrollTop):
		m.chat.ScrollToTop()
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.ScrollBottom):
		m.chat.ScrollToBottom()
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.ClearInput):
		m.input.ClearInput()
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.Palette):
		updated, cmd := m.openPalette()
		return updated, cmd

	case key.Matches[tea.KeyPressMsg](k, m.keys.Search):
		m.searchMode = true
		m.searchQuery = ""
		m.searchMatches = nil
		m.searchCursor = 0
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.PageUp),
		key.Matches[tea.KeyPressMsg](k, m.keys.PageDown):
		var cmd tea.Cmd
		m.chat, cmd = m.chat.Update(k)
		return m, cmd

	case key.Matches[tea.KeyPressMsg](k, m.keys.ScrollUp),
		key.Matches[tea.KeyPressMsg](k, m.keys.HalfPageUp):
		// Only scroll when the input is empty (not mid-edit).
		if m.input.Value() == "" {
			var cmd tea.Cmd
			m.chat, cmd = m.chat.Update(k)
			return m, cmd
		}

	case key.Matches[tea.KeyPressMsg](k, m.keys.ScrollDown),
		key.Matches[tea.KeyPressMsg](k, m.keys.HalfPageDown):
		if m.input.Value() == "" {
			var cmd tea.Cmd
			m.chat, cmd = m.chat.Update(k)
			return m, cmd
		}

	case key.Matches[tea.KeyPressMsg](k, m.keys.CopyMessage):
		if m.input.Value() == "" {
			if text := m.chat.CopyLastMessage(); text != "" {
				_ = clipboard.Copy(text)
				m.toasts.Add("Copied to clipboard", toast.ToastInfo)
				return m, m.tickCmd()
			}
			return m, nil // don't type 'y'/'c' into input when nothing to copy
		}
	}

	// Fall through: forward to input for text editing.
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(k)
	return m, cmd
}

func (m Model) handleProcessingKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	switch {
	case key.Matches[tea.KeyPressMsg](k, m.keys.Cancel),
		key.Matches[tea.KeyPressMsg](k, m.keys.Escape):
		m.cancelled = true
		m.state = StateIdle
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.chat.ClearPendingToolCalls()
		m.status.SetActive(false)
		m.chat.AddSystemMessage("Request cancelled.")
		return m, m.input.Focus()

	case key.Matches[tea.KeyPressMsg](k, m.keys.ToggleExpand):
		m.activity.SetExpanded(!m.activity.IsExpanded())
		// Cycle through chat expand states:
		// 1. If thinking has content and is not expanded → expand thinking, collapse tools
		// 2. Else if tools are not all expanded → expand all tools
		// 3. Else → collapse everything (thinking + tools)
		if m.chat.ThinkingHasContent() && !m.chat.ThinkingIsExpanded() {
			m.chat.SetThinkingExpanded(true)
			m.chat.CollapseAllTools()
		} else if !m.chat.HasExpandedTools() {
			m.chat.ExpandAllTools()
		} else {
			m.chat.SetThinkingExpanded(false)
			m.chat.CollapseAllTools()
		}
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.ToggleThinking):
		m.chat.ToggleThinkingExpanded()
		return m, nil

	case key.Matches[tea.KeyPressMsg](k, m.keys.ToggleBackground):
		m.bgTasks = append(m.bgTasks, m.activity.Summary())
		m.status.SetBackgroundCount(len(m.bgTasks))
		m.state = StateIdle
		m.chat.ClearProcessingView()
		m.toasts.Add("Task moved to background", toast.ToastInfo)
		return m, m.input.Focus()

	case key.Matches[tea.KeyPressMsg](k, m.keys.ToggleSidebar):
		return m.Update(msg.ToggleSidebar{})
	}

	if key.Matches[tea.KeyPressMsg](k, m.keys.PageUp) ||
		key.Matches[tea.KeyPressMsg](k, m.keys.PageDown) {
		var cmd tea.Cmd
		m.chat, cmd = m.chat.Update(k)
		return m, cmd
	}

	return m, nil
}

func (m Model) handlePlanKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.plan, cmd = m.plan.Update(k)
	return m, cmd
}

func (m Model) handlePickerKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	if key.Matches[tea.KeyPressMsg](k, m.keys.Cancel) {
		m.picker.Clear()
		return m, func() tea.Msg { return dialog.PickerCancel{} }
	}
	var cmd tea.Cmd
	m.picker, cmd = m.picker.Update(k)
	return m, cmd
}

func (m Model) handlePaletteKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.palette, cmd = m.palette.Update(k)
	return m, cmd
}

func (m Model) openPalette() (Model, tea.Cmd) {
	var items []dialog.PaletteItem

	// Local-only commands first.
	localCmds := []dialog.PaletteItem{
		{Name: "/help", Description: "Show available commands", Category: "system"},
		{Name: "/setup", Description: "Open setup wizard", Category: "config"},
		{Name: "/clear", Description: "Clear chat history", Category: "system"},
		{Name: "/theme", Description: "List or switch themes", Category: "system"},
		{Name: "/models", Description: "Browse & switch models", Category: "config"},
		{Name: "/sessions", Description: "List all sessions", Category: "session"},
		{Name: "/session new", Description: "Create new session", Category: "session"},
		{Name: "/bg", Description: "List background tasks", Category: "system"},
		{Name: "/exit", Description: "Exit OSA", Category: "system"},
	}
	items = append(items, localCmds...)

	// Backend commands (skip duplicates).
	seen := make(map[string]bool)
	for _, lc := range localCmds {
		seen[lc.Name] = true
	}
	for _, cmd := range m.commandEntries {
		name := "/" + cmd.Name
		if !seen[name] {
			items = append(items, dialog.PaletteItem{
				Name:        name,
				Description: cmd.Description,
				Category:    cmd.Category,
			})
		}
	}

	m.state = StatePalette
	m.input.Blur()
	openCmd := m.palette.Open(items, m.width, m.height)
	return m, openCmd
}

// -- New dialog key handlers (Wave 4) -----------------------------------------

func (m Model) handlePermissionsKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.permissions, cmd = m.permissions.Update(k)
	return m, cmd
}

func (m Model) handleQuitKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.quit, cmd = m.quit.Update(k)
	return m, cmd
}

func (m Model) handleSessionsKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	// Esc with no action — dismiss and return to idle.
	if key.Matches[tea.KeyPressMsg](k, m.keys.Escape) {
		m.state = StateIdle
		return m, m.input.Focus()
	}
	var cmd tea.Cmd
	m.sessions, cmd = m.sessions.Update(k)
	return m, cmd
}

func (m Model) handleModelsKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	if key.Matches[tea.KeyPressMsg](k, m.keys.Escape) {
		m.state = StateIdle
		return m, m.input.Focus()
	}
	var cmd tea.Cmd
	m.models, cmd = m.models.Update(k)
	return m, cmd
}
