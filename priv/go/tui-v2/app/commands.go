package app

import (
	"crypto/rand"
	"fmt"
	"io"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/config"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/chat"
	"github.com/miosa/osa-tui/ui/dialog"
	"github.com/miosa/osa-tui/ui/toast"
)

// -- Input submission ---------------------------------------------------------
func (m Model) submitInput(text string) (Model, tea.Cmd) {
	m.chat.AddUserMessage(text)

	switch {
	case text == "/exit" || text == "/quit":
		m.closeSSE()
		return m, tea.Quit

	case text == "/help":
		m.chat.AddSystemMessage(m.dynamicHelpText())
		return m, nil

	case text == "/clear":
		m.chat = chat.New(m.layout.ChatWidth, m.layout.ChatHeight)
		m.chat.SetWelcomeData(m.header.Version(), m.header.WelcomeLine(), m.header.Workspace())
		return m, nil

	case text == "/setup":
		if m.state == StateOnboarding {
			return m, nil
		}
		m.forceOnboarding = true
		m.toasts.Add("Opening setup wizard...", toast.ToastInfo)
		return m, tea.Batch(m.checkOnboarding(), m.tickCmd())

	case strings.HasPrefix(text, "/login"):
		m.toasts.Add("Authenticating...", toast.ToastInfo)
		return m, tea.Batch(m.doLogin(strings.TrimSpace(strings.TrimPrefix(text, "/login"))), m.tickCmd())

	case strings.HasPrefix(text, "/logout"):
		m.toasts.Add("Logging out...", toast.ToastInfo)
		return m, tea.Batch(m.doLogout(), m.tickCmd())

	case text == "/sessions":
		m.toasts.Add("Loading sessions...", toast.ToastInfo)
		return m, tea.Batch(m.listSessions(), m.tickCmd())

	case text == "/session" || strings.HasPrefix(text, "/session "):
		arg := strings.TrimSpace(strings.TrimPrefix(text, "/session"))
		if arg == "" {
			m.chat.AddSystemMessage("Current session: " + shortID(m.sessionID))
			return m, nil
		}
		if arg == "new" {
			m.toasts.Add("Creating session...", toast.ToastInfo)
			return m, tea.Batch(m.createSession(), m.tickCmd())
		}
		m.toasts.Add(fmt.Sprintf("Switching to session %s...", arg), toast.ToastInfo)
		return m, tea.Batch(m.switchSession(arg), m.tickCmd())

	case text == "/models":
		m.toasts.Add("Loading models...", toast.ToastInfo)
		m.input.Blur()
		return m, tea.Batch(m.fetchModels(), m.tickCmd())

	case text == "/model":
		m.pendingProviderFilter = strings.ToLower(m.header.Provider())
		m.toasts.Add(fmt.Sprintf("Loading %s models...", m.header.Provider()), toast.ToastInfo)
		m.input.Blur()
		return m, tea.Batch(m.fetchModels(), m.tickCmd())

	case strings.HasPrefix(text, "/model "):
		arg := strings.TrimSpace(strings.TrimPrefix(text, "/model"))
		parts := strings.SplitN(arg, "/", 2)
		if len(parts) == 2 {
			m.chat.AddSystemMessage(fmt.Sprintf("Switching to %s / %s...", parts[0], parts[1]))
			return m, m.switchModel(parts[0], parts[1])
		}
		if isKnownProvider(arg) {
			m.pendingProviderFilter = strings.ToLower(arg)
			m.toasts.Add(fmt.Sprintf("Loading %s models...", arg), toast.ToastInfo)
			m.input.Blur()
			return m, tea.Batch(m.fetchModels(), m.tickCmd())
		}
		// Default to ollama for bare model names (e.g. "/model qwen3:8b")
		m.chat.AddSystemMessage(fmt.Sprintf("Switching to ollama / %s...", arg))
		return m, m.switchModel("ollama", arg)

	case text == "/theme":
		var sb strings.Builder
		sb.WriteString("Available themes:\n")
		for _, name := range style.ThemeNames {
			marker := "  "
			if name == style.CurrentThemeName {
				marker = "* "
			}
			sb.WriteString(fmt.Sprintf("  %s%s\n", marker, name))
		}
		sb.WriteString("\nUsage: /theme <name>")
		m.chat.AddSystemMessage(strings.TrimRight(sb.String(), "\n"))
		return m, nil

	case strings.HasPrefix(text, "/theme "):
		name := strings.TrimSpace(strings.TrimPrefix(text, "/theme"))
		if !style.SetTheme(name) {
			m.chat.AddSystemError(fmt.Sprintf(
				"Unknown theme: %s (available: %s)", name, strings.Join(style.ThemeNames, ", "),
			))
			return m, nil
		}
		m.config.Theme = name
		if err := config.Save(profileDirPath(), m.config); err != nil {
			m.chat.AddSystemWarning(fmt.Sprintf("Theme applied but could not persist: %v", err))
		}
		m.recomputeLayout()
		m.toasts.Add(fmt.Sprintf("Theme set to: %s", name), toast.ToastInfo)
		return m, m.tickCmd()

	case text == "/bg":
		if len(m.bgTasks) == 0 {
			m.chat.AddSystemMessage("No background tasks running.")
			return m, nil
		}
		var sb strings.Builder
		sb.WriteString("Background tasks:\n")
		for i, t := range m.bgTasks {
			sb.WriteString(fmt.Sprintf("  %d. %s\n", i+1, t))
		}
		m.chat.AddSystemMessage(strings.TrimRight(sb.String(), "\n"))
		return m, nil
	}

	// Generic /command routing.
	if strings.HasPrefix(text, "/") {
		parts := strings.SplitN(text[1:], " ", 2)
		cmd := parts[0]
		if cmd == "" {
			m.chat.AddSystemMessage("Type /help for available commands, or Ctrl+K for command palette.")
			return m, nil
		}
		arg := ""
		if len(parts) > 1 {
			arg = parts[1]
		}
		m.toasts.Add(fmt.Sprintf("Running /%s...", cmd), toast.ToastInfo)
		return m, tea.Batch(m.executeCommand(cmd, arg), m.tickCmd())
	}

	// Plain text: send to agent.
	return m.submitPrompt(text)
}

// submitPrompt sends raw text directly to the agent pipeline.
func (m Model) submitPrompt(text string) (Model, tea.Cmd) {
	m.activity.Reset()
	m.activity.Start()
	m.agents.Reset()
	m.tasks.Reset()
	m.streamBuf.Reset()
	m.thinkingBuf.Reset()
	m.cancelled = false
	m.state = StateProcessing
	m.processingStart = time.Now()
	m.status.SetActive(true)
	m.chat.SetProcessingView(m.activity.View())
	m.input.Blur()
	return m, tea.Batch(m.orchestrate(text), m.tickCmd())
}

// -- Command handler ----------------------------------------------------------

func (m Model) handleCommand(r msg.CommandResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Command error: %v", r.Err))
		return m, nil
	}
	switch r.Kind {
	case "prompt":
		return m.submitPrompt(r.Output)
	case "action":
		return m.handleCommandAction(r.Action, r.Output)
	case "error":
		m.chat.AddSystemError(r.Output)
	default: // "text"
		m.chat.AddSystemMessage(r.Output)
	}
	return m, nil
}

func (m Model) handleCommandAction(action, output string) (Model, tea.Cmd) {
	switch {
	case action == ":new_session":
		m.closeSSE()
		b := make([]byte, 4)
		io.ReadFull(rand.Reader, b) //nolint:errcheck
		m.sessionID = generateSessionID(b)
		m.chat = chat.New(m.layout.ChatWidth, m.layout.ChatHeight)
		m.chat.SetWelcomeData(m.header.Version(), m.header.WelcomeLine(), m.header.Workspace())
		if output != "" {
			m.chat.AddSystemMessage(output)
		} else {
			m.chat.AddSystemMessage("New session started.")
		}
		var cmds []tea.Cmd
		cmds = append(cmds, m.input.Focus())
		if m.program != nil {
			if cmd := m.startSSE(); cmd != nil {
				cmds = append(cmds, cmd)
			}
		}
		return m, tea.Batch(cmds...)

	case action == ":exit":
		m.closeSSE()
		return m, tea.Quit

	case action == ":clear":
		m.chat = chat.New(m.layout.ChatWidth, m.layout.ChatHeight)
		m.chat.SetWelcomeData(m.header.Version(), m.header.WelcomeLine(), m.header.Workspace())
		if output != "" {
			m.chat.AddSystemMessage(output)
		}
		return m, nil

	case strings.HasPrefix(action, "{:resume_session"):
		sid := extractResumeSessionID(action)
		if sid != "" {
			m.closeSSE()
			m.sessionID = sid
			if output != "" {
				m.chat.AddSystemMessage(output)
			} else {
				m.chat.AddSystemMessage(fmt.Sprintf("Resumed session: %s", sid))
			}
			var cmds []tea.Cmd
			cmds = append(cmds, m.input.Focus())
			if m.program != nil {
				if cmd := m.startSSE(); cmd != nil {
					cmds = append(cmds, cmd)
				}
			}
			return m, tea.Batch(cmds...)
		}
		m.chat.AddSystemMessage(output)
		return m, nil

	default:
		if output != "" {
			m.chat.AddSystemMessage(output)
		}
		return m, nil
	}
}

// extractResumeSessionID extracts the session ID from an Elixir tuple string
// like "{:resume_session, \"abc123\"}" or "{:resume_session, abc123}".
func extractResumeSessionID(action string) string {
	const prefix = "{:resume_session, "
	if !strings.HasPrefix(action, prefix) {
		return ""
	}
	s := strings.TrimPrefix(action, prefix)
	s = strings.TrimSuffix(s, "}")
	s = strings.Trim(s, "\" ")
	return s
}

// -- Plan decision ------------------------------------------------------------

func (m Model) handlePlanDecision(d dialog.PlanDecision) (Model, tea.Cmd) {
	m.plan.Clear()
	switch d.Decision {
	case "approve":
		m.chat.AddSystemMessage("Plan approved. Executing...")
		m.activity.Reset()
		m.activity.Start()
		m.streamBuf.Reset()
		m.thinkingBuf.Reset()
		m.cancelled = false
		m.state = StateProcessing
		m.processingStart = time.Now()
		m.status.SetActive(true)
		return m, tea.Batch(m.orchestrateWithOpts("Approved. Execute the plan.", true), m.tickCmd())

	case "reject":
		m.chat.AddSystemMessage("Plan rejected.")
		m.state = StateIdle
		return m, m.input.Focus()

	case "edit":
		m.chat.AddSystemMessage("Edit the plan below:")
		m.state = StateIdle
		focusCmd := m.input.Focus()
		m.input.SetValue("Regarding the plan: ")
		return m, focusCmd
	}

	m.state = StateIdle
	return m, m.input.Focus()
}

func (m Model) executeCommand(cmd, arg string) tea.Cmd {
	c := m.client
	sid := m.sessionID
	return func() tea.Msg {
		resp, err := c.ExecuteCommand(client.CommandExecuteRequest{
			Command:   cmd,
			Arg:       arg,
			SessionID: sid,
		})
		if err != nil {
			return msg.CommandResult{Err: err}
		}
		return msg.CommandResult{Kind: resp.Kind, Output: resp.Output, Action: resp.Action}
	}
}

func (m Model) fetchCommands() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		commands, err := c.ListCommands()
		if err != nil {
			return commandsLoaded(nil)
		}
		return commandsLoaded(commands)
	}
}

func (m Model) handlePermissionDecision(d dialog.PermissionDecision) (Model, tea.Cmd) {
	m.state = StateIdle
	switch d.Decision {
	case "allow", "allow_session":
		m.chat.AddSystemMessage(fmt.Sprintf("Allowed: %s", d.ToolCallID))
	case "deny":
		m.chat.AddSystemWarning(fmt.Sprintf("Denied tool: %s", d.ToolCallID))
	}
	return m, m.input.Focus()
}
