package dialog

import (
	"fmt"
	"strings"

	"charm.land/bubbles/v2/key"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/logo"
)

// onboardingStep tracks which wizard screen is active.
type onboardingStep int

const (
	stepWelcome  onboardingStep = iota // 1. Agent name
	stepProfile                        // 2. User name + work context
	stepTemplate                       // 3. OS template / use case
	stepProvider                       // 4. LLM provider
	stepAPIKey                         // 5. API key (skip for Ollama)
	stepMachines                       // 6. Skill groups
	stepChannels                       // 7. Messaging channels
	stepConfirm                        // 8. Review + write
)

// OnboardingModel implements the first-run onboarding wizard.
type OnboardingModel struct {
	step       onboardingStep
	width      int
	height     int
	providers  []msg.OnboardingProvider
	templates  []msg.OnboardingTemplate
	machines   []msg.OnboardingMachine
	channels   []msg.OnboardingChannel
	systemInfo map[string]any

	// Step 1: Welcome
	nameInput InputCursor

	// Step 2: User Profile
	userNameInput    InputCursor
	userContextInput InputCursor
	profileFocus     int // 0=name, 1=context

	// Step 3: Template selection
	templateCursor int // 0 = Blank, 1+ = discovered templates

	// Step 4: Provider selection
	providerCursor int

	// Step 5: API Key
	keyInput InputCursor

	// Step 6: Machines
	machineToggles map[string]bool

	// Step 7: Channels
	channelToggles map[string]bool

	// Step 8: Confirm
	confirmFocused int // 0=Confirm, 1=Back

	err string
}

// NewOnboarding creates a new onboarding wizard model.
func NewOnboarding() OnboardingModel {
	name := InputCursor{Value: "OSA", Cursor: 3, Focused: true}
	return OnboardingModel{
		step:             stepWelcome,
		nameInput:        name,
		userNameInput:    InputCursor{Focused: false},
		userContextInput: InputCursor{Focused: false},
		width:            80,
		height:           24,
		machineToggles:   make(map[string]bool),
		channelToggles:   make(map[string]bool),
	}
}

// SetSize updates the dialog dimensions.
func (m *OnboardingModel) SetSize(w, h int) {
	m.width = w
	m.height = h
}

// SetProviders loads data from the backend.
func (m *OnboardingModel) SetProviders(providers []msg.OnboardingProvider, sysInfo map[string]any) {
	m.providers = providers
	m.systemInfo = sysInfo
}

// SetTemplates loads discovered OS templates.
func (m *OnboardingModel) SetTemplates(templates []msg.OnboardingTemplate) {
	m.templates = templates
}

// SetMachines loads available machine groups.
func (m *OnboardingModel) SetMachines(machines []msg.OnboardingMachine) {
	m.machines = machines
	for _, mach := range machines {
		m.machineToggles[mach.Key] = false
	}
}

// SetChannels loads available channels.
func (m *OnboardingModel) SetChannels(channels []msg.OnboardingChannel) {
	m.channels = channels
	for _, ch := range channels {
		m.channelToggles[ch.Key] = false
	}
}

// SetError displays an error message on the confirm screen and resets focus to Confirm button.
func (m *OnboardingModel) SetError(err string) {
	m.err = err
	m.confirmFocused = 0
}

// Update processes a key press and returns an optional tea.Cmd.
func (m *OnboardingModel) Update(k tea.KeyPressMsg) tea.Cmd {
	if key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("ctrl+c"))) {
		return tea.Quit
	}

	switch m.step {
	case stepWelcome:
		return m.updateWelcome(k)
	case stepProfile:
		return m.updateProfile(k)
	case stepTemplate:
		return m.updateTemplate(k)
	case stepProvider:
		return m.updateProvider(k)
	case stepAPIKey:
		return m.updateAPIKey(k)
	case stepMachines:
		return m.updateMachines(k)
	case stepChannels:
		return m.updateChannels(k)
	case stepConfirm:
		return m.updateConfirm(k)
	}
	return nil
}

// ── Step 1: Welcome ─────────────────────────────────────────

func (m *OnboardingModel) updateWelcome(k tea.KeyPressMsg) tea.Cmd {
	switch {
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("enter"))):
		if strings.TrimSpace(m.nameInput.Value) == "" {
			m.nameInput.SetValue("OSA")
		}
		m.step = stepProfile
		m.nameInput.Focused = false
		m.userNameInput.Focused = true
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("backspace"))):
		m.nameInput.Backspace()
		return nil
	default:
		if k.Text != "" {
			for _, r := range k.Text {
				m.nameInput.Insert(r)
			}
		}
		return nil
	}
}

// ── Step 2: User Profile ─────────────────────────────────────

func (m *OnboardingModel) updateProfile(k tea.KeyPressMsg) tea.Cmd {
	switch {
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("enter"))):
		if m.profileFocus == 0 {
			// Move to context field
			m.profileFocus = 1
			m.userNameInput.Focused = false
			m.userContextInput.Focused = true
			return nil
		}
		// Both fields done, move to template
		m.step = stepTemplate
		m.userContextInput.Focused = false
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("tab"))):
		// Toggle between name and context
		if m.profileFocus == 0 {
			m.profileFocus = 1
			m.userNameInput.Focused = false
			m.userContextInput.Focused = true
		} else {
			m.profileFocus = 0
			m.userNameInput.Focused = true
			m.userContextInput.Focused = false
		}
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("escape"))):
		m.step = stepWelcome
		m.nameInput.Focused = true
		m.userNameInput.Focused = false
		m.userContextInput.Focused = false
		m.profileFocus = 0
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("backspace"))):
		if m.profileFocus == 0 {
			m.userNameInput.Backspace()
		} else {
			m.userContextInput.Backspace()
		}
		return nil
	default:
		if k.Text != "" {
			for _, r := range k.Text {
				if m.profileFocus == 0 {
					m.userNameInput.Insert(r)
				} else {
					m.userContextInput.Insert(r)
				}
			}
		}
		return nil
	}
}

// ── Step 3: OS Template ─────────────────────────────────────

func (m *OnboardingModel) updateTemplate(k tea.KeyPressMsg) tea.Cmd {
	maxIdx := len(m.templates) // 0=Blank, 1..N = templates
	switch {
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("up", "k"))):
		if m.templateCursor > 0 {
			m.templateCursor--
		}
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("down", "j"))):
		if m.templateCursor < maxIdx {
			m.templateCursor++
		}
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("enter"))):
		m.step = stepProvider
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("escape"))):
		m.step = stepProfile
		m.userContextInput.Focused = true
		m.profileFocus = 1
		return nil
	}
	return nil
}

// ── Step 4: Provider ─────────────────────────────────────────

func (m *OnboardingModel) updateProvider(k tea.KeyPressMsg) tea.Cmd {
	maxIdx := len(m.providers) - 1
	if maxIdx < 0 {
		maxIdx = 0
	}
	switch {
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("up", "k"))):
		if m.providerCursor > 0 {
			m.providerCursor--
		}
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("down", "j"))):
		if m.providerCursor < maxIdx {
			m.providerCursor++
		}
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("enter"))):
		selected := m.selectedProvider() // safe fallback if providers is empty
		if selected.EnvVar == "" {
			m.step = stepMachines
		} else {
			m.step = stepAPIKey
			m.keyInput = InputCursor{Focused: true}
		}
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("escape"))):
		m.step = stepTemplate
		return nil
	}
	return nil
}

// ── Step 5: API Key ─────────────────────────────────────────

func (m *OnboardingModel) updateAPIKey(k tea.KeyPressMsg) tea.Cmd {
	switch {
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("enter"))):
		m.step = stepMachines
		m.keyInput.Focused = false
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("escape"))):
		m.step = stepProvider
		m.keyInput.Focused = false
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("backspace"))):
		m.keyInput.Backspace()
		return nil
	default:
		if k.Text != "" {
			for _, r := range k.Text {
				m.keyInput.Insert(r)
			}
		}
		return nil
	}
}

// ── Step 6: Machines ─────────────────────────────────────────

func (m *OnboardingModel) updateMachines(k tea.KeyPressMsg) tea.Cmd {
	switch {
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("enter"))):
		m.step = stepChannels
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("escape"))):
		selected := m.selectedProvider()
		if selected.EnvVar == "" {
			m.step = stepProvider
		} else {
			m.step = stepAPIKey
			m.keyInput.Focused = true // preserve existing key value
		}
		return nil
	default:
		// Number keys toggle machines: 1=first, 2=second, etc.
		if k.Text != "" {
			for i, mach := range m.machines {
				if k.Text == fmt.Sprintf("%d", i+1) {
					m.machineToggles[mach.Key] = !m.machineToggles[mach.Key]
					return nil
				}
			}
		}
		return nil
	}
}

// ── Step 7: Channels ─────────────────────────────────────────

func (m *OnboardingModel) updateChannels(k tea.KeyPressMsg) tea.Cmd {
	switch {
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("enter"))):
		m.step = stepConfirm
		m.confirmFocused = 0
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("escape"))):
		m.step = stepMachines
		return nil
	default:
		if k.Text != "" {
			for i, ch := range m.channels {
				if k.Text == fmt.Sprintf("%d", i+1) {
					m.channelToggles[ch.Key] = !m.channelToggles[ch.Key]
					return nil
				}
			}
		}
		return nil
	}
}

// ── Step 8: Confirm ─────────────────────────────────────────

func (m *OnboardingModel) updateConfirm(k tea.KeyPressMsg) tea.Cmd {
	switch {
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("tab", "shift+tab", "left", "right"))):
		m.confirmFocused = 1 - m.confirmFocused
		return nil
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("enter"))):
		if m.confirmFocused == 1 {
			m.step = stepChannels
			return nil
		}
		selected := m.selectedProvider()

		// Collect selected channels
		var selChannels []string
		for _, ch := range m.channels {
			if m.channelToggles[ch.Key] {
				selChannels = append(selChannels, ch.Key)
			}
		}

		// Collect OS template
		var osTemplate map[string]string
		if m.templateCursor > 0 && m.templateCursor <= len(m.templates) {
			t := m.templates[m.templateCursor-1]
			osTemplate = map[string]string{"name": t.Name, "path": t.Path}
		}

		return func() tea.Msg {
			return OnboardingDone{
				Provider:    selected.Key,
				Model:       selected.DefaultModel,
				APIKey:      m.keyInput.Value,
				EnvVar:      selected.EnvVar,
				AgentName:   m.nameInput.Value,
				UserName:    m.userNameInput.Value,
				UserContext: m.userContextInput.Value,
				Machines:    m.machineToggles,
				Channels:    selChannels,
				OSTemplate:  osTemplate,
			}
		}
	case key.Matches[tea.KeyPressMsg](k, key.NewBinding(key.WithKeys("escape"))):
		m.step = stepChannels
		return nil
	}
	return nil
}

// ── Views ───────────────────────────────────────────────────

func (m OnboardingModel) View() string {
	var content string
	switch m.step {
	case stepWelcome:
		content = m.viewWelcome()
	case stepProfile:
		content = m.viewProfile()
	case stepTemplate:
		content = m.viewTemplate()
	case stepProvider:
		content = m.viewProvider()
	case stepAPIKey:
		content = m.viewAPIKey()
	case stepMachines:
		content = m.viewMachines()
	case stepChannels:
		content = m.viewChannels()
	case stepConfirm:
		content = m.viewConfirm()
	}
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, content)
}

func (m OnboardingModel) boxWidth() int {
	w := m.width - 4
	if w < 40 {
		w = 40
	}
	if w > 60 {
		w = 60
	}
	return w
}

func (m OnboardingModel) stepIndicator(current int) string {
	var parts []string
	labels := []string{"Name", "Profile", "Template", "Provider", "Key", "Skills", "Channels", "Confirm"}
	for i, label := range labels {
		num := fmt.Sprintf("%d", i+1)
		if i == current {
			parts = append(parts, style.RadioOn.Render(num)+style.Bold.Render(" "+label))
		} else if i < current {
			parts = append(parts, style.TaskDone.Render(num+" "+label))
		} else {
			parts = append(parts, style.Faint.Render(num+" "+label))
		}
	}
	return style.Faint.Render(strings.Join(parts, " \u00b7 "))
}

// ── Step 1: Welcome View ────────────────────────────────────

func (m OnboardingModel) viewWelcome() string {
	w := m.boxWidth()
	var b strings.Builder

	b.WriteString(logo.RenderWithGradient(w))
	b.WriteString("\n\n")

	b.WriteString(style.Bold.Render("Welcome to OSA") + "\n")
	b.WriteString(style.Faint.Render(strings.Repeat("\u2500", 24)) + "\n")

	// System info
	if m.systemInfo != nil {
		var infoParts []string
		if os, ok := m.systemInfo["os"].(string); ok {
			infoParts = append(infoParts, "OS: "+os)
		}
		if shell, ok := m.systemInfo["shell"].(string); ok {
			parts := strings.Split(shell, "/")
			infoParts = append(infoParts, "Shell: "+parts[len(parts)-1])
		}
		if ollama, ok := m.systemInfo["ollama"].([]any); ok && len(ollama) > 0 {
			if statusVal, ok := ollama[0].(string); ok && statusVal == "running" {
				count := 0
				if len(ollama) > 1 {
					if c, ok := ollama[1].(float64); ok {
						count = int(c)
					}
				}
				infoParts = append(infoParts, fmt.Sprintf("Ollama: %s %d", style.TaskDone.Render("\u2713"), count))
			}
		}
		if ollama, ok := m.systemInfo["ollama"].(string); ok {
			if ollama == "running" {
				infoParts = append(infoParts, "Ollama: "+style.TaskDone.Render("\u2713"))
			} else {
				infoParts = append(infoParts, "Ollama: "+style.Faint.Render("\u2717"))
			}
		}
		if len(infoParts) > 0 {
			b.WriteString(style.Faint.Render(strings.Join(infoParts, " \u00b7 ")) + "\n")
		}
	}

	b.WriteString("\n")
	b.WriteString(style.Faint.Render("Agent name: ") + m.nameInput.View() + "\n\n")

	b.WriteString(RenderButtons([]ButtonDef{
		{Label: "Continue", Active: true, Underline: -1},
	}, w) + "\n")

	b.WriteString(RenderHelpBar([]HelpItem{
		{Key: "enter", Desc: "continue"},
		{Key: "ctrl+c", Desc: "quit"},
	}, w))

	return style.DialogBorder.Width(w).Render(b.String())
}

// ── Step 2: Profile View ────────────────────────────────────

func (m OnboardingModel) viewProfile() string {
	w := m.boxWidth()
	var b strings.Builder

	b.WriteString(m.stepIndicator(1) + "\n\n")
	b.WriteString(GradientTitle("Your Profile") + "\n")
	b.WriteString(style.Faint.Render(strings.Repeat("\u2500", 24)) + "\n")
	b.WriteString(style.Faint.Render("Tell me about yourself (optional):") + "\n\n")

	// Name field
	nameLabel := style.Faint.Render("Name:    ")
	if m.profileFocus == 0 {
		nameLabel = style.Bold.Render("Name:    ")
	}
	b.WriteString(nameLabel + m.userNameInput.View() + "\n\n")

	// Context field
	ctxLabel := style.Faint.Render("Work on: ")
	if m.profileFocus == 1 {
		ctxLabel = style.Bold.Render("Work on: ")
	}
	b.WriteString(ctxLabel + m.userContextInput.View() + "\n")
	b.WriteString(style.Faint.Render("  (e.g., \"SaaS platform in Go/Svelte\")") + "\n\n")

	b.WriteString(RenderButtons([]ButtonDef{
		{Label: "Continue", Active: true, Underline: -1},
	}, w) + "\n")

	b.WriteString(RenderHelpBar([]HelpItem{
		{Key: "tab", Desc: "switch field"},
		{Key: "enter", Desc: "continue"},
		{Key: "esc", Desc: "back"},
	}, w))

	return style.DialogBorder.Width(w).Render(b.String())
}

// ── Step 3: Template View ───────────────────────────────────

func (m OnboardingModel) viewTemplate() string {
	w := m.boxWidth()
	var b strings.Builder

	b.WriteString(m.stepIndicator(2) + "\n\n")
	b.WriteString(GradientTitle("Use Case") + "\n")
	b.WriteString(style.Faint.Render(strings.Repeat("\u2500", 24)) + "\n")
	b.WriteString(style.Faint.Render("How will you use OSA?") + "\n\n")

	// Option 0: Blank / General Purpose
	cursor := "  "
	radio := style.RadioOff.Render("\u25cb")
	nameStyle := style.Faint
	if m.templateCursor == 0 {
		cursor = style.PrefixActive.Render("> ")
		radio = style.RadioOn.Render("\u25cf")
		nameStyle = style.Bold
	}
	b.WriteString(fmt.Sprintf("%s%s %s\n", cursor, radio, nameStyle.Render("Blank / General Purpose")))
	if m.templateCursor == 0 {
		b.WriteString(style.Faint.Render("     Custom setup \u2014 configure everything yourself") + "\n")
	}

	// Discovered templates
	for i, t := range m.templates {
		idx := i + 1
		cursor = "  "
		radio = style.RadioOff.Render("\u25cb")
		nameStyle = style.Faint
		if m.templateCursor == idx {
			cursor = style.PrefixActive.Render("> ")
			radio = style.RadioOn.Render("\u25cf")
			nameStyle = style.Bold
		}

		label := t.Name
		if t.Modules > 0 {
			label += style.Faint.Render(fmt.Sprintf(" (%d modules)", t.Modules))
		}
		b.WriteString(fmt.Sprintf("%s%s %s\n", cursor, radio, nameStyle.Render(label)))
		if m.templateCursor == idx {
			// Show stack info
			var stackParts []string
			if backend, ok := t.Stack["backend"].(string); ok {
				stackParts = append(stackParts, "backend: "+backend)
			}
			if frontend, ok := t.Stack["frontend"].(string); ok {
				stackParts = append(stackParts, "frontend: "+frontend)
			}
			if db, ok := t.Stack["database"].(string); ok {
				stackParts = append(stackParts, "db: "+db)
			}
			if len(stackParts) > 0 {
				b.WriteString(style.Faint.Render("     "+strings.Join(stackParts, " \u00b7 ")) + "\n")
			}
			b.WriteString(style.Faint.Render("     "+t.Path) + "\n")
		}
	}

	if len(m.templates) == 0 {
		b.WriteString("\n" + style.Faint.Render("  No OS templates discovered.") + "\n")
		b.WriteString(style.Faint.Render("  Add .osa-manifest.json to a project to connect it.") + "\n")
	}

	b.WriteString("\n")
	b.WriteString(RenderHelpBar([]HelpItem{
		{Key: "\u2191\u2193", Desc: "navigate"},
		{Key: "enter", Desc: "select"},
		{Key: "esc", Desc: "back"},
	}, w))

	return style.DialogBorder.Width(w).Render(b.String())
}

// ── Step 4: Provider View ───────────────────────────────────

func (m OnboardingModel) viewProvider() string {
	w := m.boxWidth()
	var b strings.Builder

	b.WriteString(m.stepIndicator(3) + "\n\n")
	b.WriteString(GradientTitle("Select Provider") + "\n")
	b.WriteString(style.Faint.Render(strings.Repeat("\u2500", 24)) + "\n\n")

	localHeader := style.SectionTitle.Render("Local")
	cloudHeader := style.SectionTitle.Render("Cloud")
	localWritten := false
	cloudWritten := false

	maxVisible := m.height - 16
	if maxVisible < 5 {
		maxVisible = 5
	}

	startIdx := 0
	if m.providerCursor >= maxVisible {
		startIdx = m.providerCursor - maxVisible + 1
	}
	endIdx := startIdx + maxVisible
	if endIdx > len(m.providers) {
		endIdx = len(m.providers)
	}

	for i := startIdx; i < endIdx; i++ {
		p := m.providers[i]
		if p.EnvVar == "" && !localWritten {
			b.WriteString(localHeader + "\n")
			localWritten = true
		} else if p.EnvVar != "" && !cloudWritten {
			if localWritten {
				b.WriteString("\n")
			}
			b.WriteString(cloudHeader + "\n")
			cloudWritten = true
		}

		cursor := "  "
		radio := style.RadioOff.Render("\u25cb")
		nameStyle := style.Faint
		if i == m.providerCursor {
			cursor = style.PrefixActive.Render("> ")
			radio = style.RadioOn.Render("\u25cf")
			nameStyle = style.Bold
		}

		line := fmt.Sprintf("%s%s %s", cursor, radio, nameStyle.Render(p.Name))
		if i == m.providerCursor {
			line += style.Faint.Render("  " + p.DefaultModel)
		}
		b.WriteString(line + "\n")
	}

	if endIdx < len(m.providers) {
		b.WriteString(style.Faint.Render(fmt.Sprintf("  ... %d more", len(m.providers)-endIdx)) + "\n")
	}

	b.WriteString("\n")
	b.WriteString(RenderHelpBar([]HelpItem{
		{Key: "\u2191\u2193", Desc: "navigate"},
		{Key: "enter", Desc: "select"},
		{Key: "esc", Desc: "back"},
	}, w))

	return style.DialogBorder.Width(w).Render(b.String())
}

// ── Step 5: API Key View ────────────────────────────────────

func (m OnboardingModel) viewAPIKey() string {
	w := m.boxWidth()
	selected := m.selectedProvider()
	var b strings.Builder

	b.WriteString(m.stepIndicator(4) + "\n\n")
	b.WriteString(GradientTitle("API Key") + "\n")
	b.WriteString(style.Faint.Render(strings.Repeat("\u2500", 24)) + "\n\n")

	b.WriteString(style.Bold.Render("Provider: ") + style.AgentName.Render(selected.Name) + "\n")
	b.WriteString(style.Bold.Render("Model:    ") + style.Faint.Render(selected.DefaultModel) + "\n")
	if selected.EnvVar != "" {
		b.WriteString(style.Bold.Render("Env var:  ") + style.Faint.Render(selected.EnvVar) + "\n")
	}
	b.WriteString("\n")

	b.WriteString(style.Faint.Render("API key: ") + m.maskedKeyView() + "\n")
	b.WriteString(style.Faint.Render("  (leave empty if already set via env var)") + "\n\n")

	b.WriteString(RenderButtons([]ButtonDef{
		{Label: "Continue", Active: true, Underline: -1},
	}, w) + "\n")

	b.WriteString(RenderHelpBar([]HelpItem{
		{Key: "enter", Desc: "continue"},
		{Key: "esc", Desc: "back"},
	}, w))

	return style.DialogBorder.Width(w).Render(b.String())
}

// ── Step 6: Machines View ───────────────────────────────────

func (m OnboardingModel) viewMachines() string {
	w := m.boxWidth()
	var b strings.Builder

	b.WriteString(m.stepIndicator(5) + "\n\n")
	b.WriteString(GradientTitle("Skill Groups") + "\n")
	b.WriteString(style.Faint.Render(strings.Repeat("\u2500", 24)) + "\n")
	b.WriteString(style.Faint.Render("Enable tool groups for your agent:") + "\n\n")

	for i, mach := range m.machines {
		num := style.AgentName.Render(fmt.Sprintf("[%d]", i+1))
		check := style.RadioOff.Render("\u2610")
		if m.machineToggles[mach.Key] {
			check = style.RadioOn.Render("\u2611")
		}
		name := style.Bold.Render(mach.Name)
		desc := style.Faint.Render(mach.Description)
		b.WriteString(fmt.Sprintf("  %s %s %s  %s\n", num, check, name, desc))
	}

	b.WriteString("\n")
	b.WriteString(style.Faint.Render("  Core tools (file, shell, web) are always enabled.") + "\n\n")

	b.WriteString(RenderButtons([]ButtonDef{
		{Label: "Continue", Active: true, Underline: -1},
	}, w) + "\n")

	b.WriteString(RenderHelpBar([]HelpItem{
		{Key: "1-3", Desc: "toggle"},
		{Key: "enter", Desc: "continue"},
		{Key: "esc", Desc: "back"},
	}, w))

	return style.DialogBorder.Width(w).Render(b.String())
}

// ── Step 7: Channels View ───────────────────────────────────

func (m OnboardingModel) viewChannels() string {
	w := m.boxWidth()
	var b strings.Builder

	b.WriteString(m.stepIndicator(6) + "\n\n")
	b.WriteString(GradientTitle("Channels") + "\n")
	b.WriteString(style.Faint.Render(strings.Repeat("\u2500", 24)) + "\n")
	b.WriteString(style.Faint.Render("Connect messaging platforms (configure tokens later):") + "\n\n")

	for i, ch := range m.channels {
		num := style.AgentName.Render(fmt.Sprintf("[%d]", i+1))
		check := style.RadioOff.Render("\u2610")
		if m.channelToggles[ch.Key] {
			check = style.RadioOn.Render("\u2611")
		}
		name := style.Bold.Render(ch.Name)
		desc := style.Faint.Render(ch.Description)
		b.WriteString(fmt.Sprintf("  %s %s %s  %s\n", num, check, name, desc))
	}

	b.WriteString("\n")
	b.WriteString(style.Faint.Render("  Channel tokens configured after setup via /channels.") + "\n\n")

	b.WriteString(RenderButtons([]ButtonDef{
		{Label: "Continue", Active: true, Underline: -1},
	}, w) + "\n")

	b.WriteString(RenderHelpBar([]HelpItem{
		{Key: "1-4", Desc: "toggle"},
		{Key: "enter", Desc: "continue"},
		{Key: "esc", Desc: "back"},
	}, w))

	return style.DialogBorder.Width(w).Render(b.String())
}

// ── Step 8: Confirm View ────────────────────────────────────

func (m OnboardingModel) viewConfirm() string {
	w := m.boxWidth()
	selected := m.selectedProvider()
	var b strings.Builder

	b.WriteString(m.stepIndicator(7) + "\n\n")
	b.WriteString(GradientTitle("Confirm Setup") + "\n")
	b.WriteString(style.Faint.Render(strings.Repeat("\u2500", 24)) + "\n\n")

	// Summary
	b.WriteString(style.Bold.Render("Agent:    ") + style.AgentName.Render(m.nameInput.Value) + "\n")

	// User profile
	if m.userNameInput.Value != "" || m.userContextInput.Value != "" {
		profileParts := []string{}
		if m.userNameInput.Value != "" {
			profileParts = append(profileParts, m.userNameInput.Value)
		}
		if m.userContextInput.Value != "" {
			profileParts = append(profileParts, m.userContextInput.Value)
		}
		b.WriteString(style.Bold.Render("User:     ") + style.Faint.Render(strings.Join(profileParts, " — ")) + "\n")
	}

	// Template
	if m.templateCursor == 0 {
		b.WriteString(style.Bold.Render("Template: ") + style.Faint.Render("Blank") + "\n")
	} else if m.templateCursor <= len(m.templates) {
		t := m.templates[m.templateCursor-1]
		b.WriteString(style.Bold.Render("Template: ") + style.AgentName.Render(t.Name) + "\n")
	}

	b.WriteString(style.Bold.Render("Provider: ") + style.AgentName.Render(selected.Name) + "\n")
	b.WriteString(style.Bold.Render("Model:    ") + style.Faint.Render(selected.DefaultModel) + "\n")

	if m.keyInput.Value != "" {
		b.WriteString(style.Bold.Render("API Key:  ") + style.Faint.Render("\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022") + "\n")
	} else if selected.EnvVar != "" {
		b.WriteString(style.Bold.Render("API Key:  ") + style.Faint.Render("(from "+selected.EnvVar+")") + "\n")
	}

	// Machines
	var enabledMachines []string
	for _, mach := range m.machines {
		if m.machineToggles[mach.Key] {
			enabledMachines = append(enabledMachines, mach.Name)
		}
	}
	if len(enabledMachines) > 0 {
		b.WriteString(style.Bold.Render("Skills:   ") + style.Faint.Render(strings.Join(enabledMachines, ", ")) + "\n")
	} else {
		b.WriteString(style.Bold.Render("Skills:   ") + style.Faint.Render("Core only") + "\n")
	}

	// Channels
	var enabledChannels []string
	for _, ch := range m.channels {
		if m.channelToggles[ch.Key] {
			enabledChannels = append(enabledChannels, ch.Name)
		}
	}
	if len(enabledChannels) > 0 {
		b.WriteString(style.Bold.Render("Channels: ") + style.Faint.Render(strings.Join(enabledChannels, ", ")) + "\n")
	} else {
		b.WriteString(style.Bold.Render("Channels: ") + style.Faint.Render("None (CLI only)") + "\n")
	}

	b.WriteString("\n")
	b.WriteString(style.Faint.Render("Files to write:") + "\n")
	b.WriteString(style.Faint.Render("  ~/.osa/config.json") + "\n")
	b.WriteString(style.Faint.Render("  ~/.osa/IDENTITY.md") + "\n")
	b.WriteString(style.Faint.Render("  ~/.osa/USER.md") + "\n")
	b.WriteString(style.Faint.Render("  ~/.osa/SOUL.md") + "\n")
	b.WriteString("\n")

	if m.err != "" {
		b.WriteString(style.ErrorText.Render("Error: "+m.err) + "\n\n")
	}

	b.WriteString(RenderButtons([]ButtonDef{
		{Label: "Confirm", Active: m.confirmFocused == 0, Underline: -1},
		{Label: "Back", Active: m.confirmFocused == 1, Underline: -1},
	}, w) + "\n")

	b.WriteString(RenderHelpBar([]HelpItem{
		{Key: "tab", Desc: "switch"},
		{Key: "enter", Desc: "confirm"},
		{Key: "esc", Desc: "back"},
	}, w))

	return style.DialogBorder.Width(w).Render(b.String())
}

// ── Helpers ─────────────────────────────────────────────────

func (m OnboardingModel) selectedProvider() msg.OnboardingProvider {
	if m.providerCursor < len(m.providers) {
		return m.providers[m.providerCursor]
	}
	return msg.OnboardingProvider{Key: "ollama", Name: "Ollama", DefaultModel: "llama3.2:latest"}
}

func (m OnboardingModel) maskedKeyView() string {
	val := m.keyInput.Value
	if val == "" {
		if m.keyInput.Focused {
			return style.ButtonActive.Render(" ")
		}
		return style.Faint.Render("(empty)")
	}

	runes := []rune(val)
	n := len(runes)
	if n <= 4 {
		masked := strings.Repeat("\u2022", n)
		if m.keyInput.Focused {
			return masked + style.ButtonActive.Render(" ")
		}
		return style.Faint.Render(masked)
	}

	masked := strings.Repeat("\u2022", n-4) + string(runes[n-4:])
	if m.keyInput.Focused {
		return masked + style.ButtonActive.Render(" ")
	}
	return style.Faint.Render(masked)
}
