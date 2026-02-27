package app

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/model"
	"github.com/miosa/osa-tui/msg"
)

// ProfileDir is set by main.go based on --profile flag.
var ProfileDir string

func profileDirPath() string {
	return ProfileDir
}

const maxMessageSize = 100_000 // 100KB

func truncateResponse(s string) string {
	if len(s) > maxMessageSize {
		return s[:maxMessageSize] + "\n\n… (response truncated at 100KB)"
	}
	return s
}

// ProgramReady is sent from main.go to inject the *tea.Program reference.
type ProgramReady struct {
	Program *tea.Program
}

// Model is the root bubbletea model composing all sub-models.
type Model struct {
	// Sub-models
	banner   model.BannerModel
	chat     model.ChatModel
	input    model.InputModel
	activity model.ActivityModel
	tasks    model.TasksModel
	status   model.StatusModel
	plan     model.PlanModel
	agents   model.AgentsModel

	// State
	state     State
	prevState State

	// Connection
	client    *client.Client
	sse       *client.SSEClient
	program   *tea.Program
	sessionID string

	// Layout
	width  int
	height int

	// Key bindings
	keys KeyMap

	// Background tasks
	bgTasks []string

	// Confirm quit
	confirmQuit bool

	// Elapsed timer
	processingStart time.Time
}

// New creates the root app model.
func New(c *client.Client) Model {
	return Model{
		banner:   model.NewBanner(),
		chat:     model.NewChat(80, 20),
		input:    model.NewInput(),
		activity: model.NewActivity(),
		tasks:    model.NewTasks(),
		status:   model.NewStatus(),
		plan:     model.NewPlan(),
		agents:   model.NewAgents(),
		state:    StateConnecting,
		client:   c,
		keys:     DefaultKeyMap(),
		width:    80,
		height:   24,
	}
}

// Init starts the health check.
func (m Model) Init() tea.Cmd {
	return tea.Batch(
		m.checkHealth(),
		m.input.Init(),
		m.activity.Init(),
		tea.WindowSize(),
	)
}

// Update handles all messages.
func (m Model) Update(rawMsg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch v := rawMsg.(type) {
	case tea.WindowSizeMsg:
		m.width = v.Width
		m.height = v.Height
		m.chat.SetSize(v.Width, m.chatHeight())
		m.plan.SetWidth(v.Width - 4)
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(v)

	// -- Program reference injection --

	case ProgramReady:
		m.program = v.Program
		// If health already succeeded and SSE not started yet, start it now
		if m.sessionID != "" && m.sse == nil {
			return m, m.startSSE()
		}
		return m, nil

	// -- HTTP result messages (from tea.Cmd closures) --

	case msg.HealthResult:
		return m.handleHealth(v)

	case msg.OrchestrateResult:
		return m.handleOrchestrate(v)

	case msg.CommandResult:
		return m.handleCommand(v)

	case commandsLoaded:
		m.input.SetCommands([]string(v))
		return m, nil

	case toolCountLoaded:
		m.banner.SetToolCount(int(v))
		return m, nil

	// -- SSE lifecycle events (from client.SSEClient → p.Send) --

	case client.SSEConnectedEvent:
		m.sessionID = v.SessionID
		return m, nil

	case client.SSEDisconnectedEvent:
		// Only reconnect if the disconnect was unintentional
		if m.sessionID != "" && m.sse != nil && !m.sse.IsClosed() && m.program != nil {
			return m, m.sse.ListenCmd(m.program)
		}
		return m, nil

	case client.SSEAuthFailedEvent:
		m.chat.AddSystemMessage("⚠ Authentication expired. Use /login to re-authenticate.")
		m.closeSSE()
		m.state = StateIdle
		return m, m.input.Focus()

	case msg.LoginResult:
		if v.Err != nil {
			m.chat.AddSystemMessage(fmt.Sprintf("Login failed: %v", v.Err))
		} else {
			m.chat.AddSystemMessage(fmt.Sprintf("✓ Authenticated (token expires in %ds)", v.ExpiresIn))
			// Restart SSE with new token
			if m.sse != nil {
				m.closeSSE()
			}
			if m.program != nil && m.sessionID != "" {
				return m, m.startSSE()
			}
		}
		return m, nil

	case msg.LogoutResult:
		if v.Err != nil {
			m.chat.AddSystemMessage(fmt.Sprintf("Logout error: %v", v.Err))
		} else {
			m.chat.AddSystemMessage("✓ Logged out")
			m.closeSSE()
		}
		return m, nil

	case retryHealth:
		return m, m.checkHealth()

	// -- SSE data events (dispatched by client/sse.go → p.Send) --

	case client.AgentResponseEvent:
		return m.handleClientAgentResponse(v)

	case client.LLMRequestEvent:
		m.activity.Update(msg.LLMRequest{Iteration: v.Iteration})
		return m, nil

	case client.ToolCallStartEvent:
		m.activity.Update(msg.ToolCallStart{Name: v.Name, Args: v.Args})
		return m, nil

	case client.ToolCallEndEvent:
		m.activity.Update(msg.ToolCallEnd{Name: v.Name, DurationMs: v.DurationMs, Success: v.Success})
		return m, nil

	case client.LLMResponseEvent:
		m.activity.Update(msg.LLMResponse{
			DurationMs:   v.DurationMs,
			InputTokens:  v.InputTokens,
			OutputTokens: v.OutputTokens,
		})
		m.status.SetStats(
			time.Since(m.processingStart),
			m.activity.ToolCount(),
			v.InputTokens,
			v.OutputTokens,
		)
		return m, nil

	case client.ContextPressureEvent:
		m.status.SetContext(v.Utilization, v.MaxTokens)
		return m, nil

	// -- SSE orchestrator events --

	case client.OrchestratorTaskStartedEvent:
		m.agents.Start()
		return m, nil

	case client.OrchestratorWaveStartedEvent:
		m.agents.Update(msg.OrchestratorWaveStarted{WaveNumber: v.WaveNumber, TotalWaves: v.TotalWaves})
		return m, nil

	case client.OrchestratorAgentStartedEvent:
		m.agents.Update(msg.OrchestratorAgentStarted{AgentName: v.AgentName, Role: v.Role, Model: v.Model})
		return m, nil

	case client.OrchestratorAgentProgressEvent:
		m.agents.Update(msg.OrchestratorAgentProgress{
			AgentName: v.AgentName, CurrentAction: v.CurrentAction,
			ToolUses: v.ToolUses, TokensUsed: v.TokensUsed,
		})
		return m, nil

	case client.OrchestratorAgentCompletedEvent:
		m.agents.Update(msg.OrchestratorAgentCompleted{
			AgentName: v.AgentName, ToolUses: v.ToolUses, TokensUsed: v.TokensUsed,
		})
		return m, nil

	case client.OrchestratorTaskCompletedEvent:
		m.agents.Stop()
		return m, nil

	// -- UI events --

	case msg.ToggleExpand:
		m.activity.Update(v)
		m.tasks.Update(v)
		m.agents.Update(v)
		return m, nil

	case msg.TickMsg:
		if m.state == StateProcessing {
			m.status.SetStats(
				time.Since(m.processingStart),
				m.activity.ToolCount(),
				m.activity.InputTokens(),
				m.activity.OutputTokens(),
			)
			cmds = append(cmds, m.tickCmd())
		}
		var cmd tea.Cmd
		m.activity, cmd = m.activity.Update(rawMsg)
		cmds = append(cmds, cmd)
		return m, tea.Batch(cmds...)

	case model.PlanDecision:
		return m.handlePlanDecision(v)
	}

	// Forward spinner ticks to activity
	if m.state == StateProcessing {
		var cmd tea.Cmd
		m.activity, cmd = m.activity.Update(rawMsg)
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}

// View renders the full TUI.
func (m Model) View() string {
	var sections []string

	switch m.state {
	case StateConnecting:
		sections = append(sections, m.renderConnecting())

	case StateBanner:
		sections = append(sections, m.banner.View())
		sections = append(sections, "")
		sections = append(sections, m.chat.View())
		sections = append(sections, m.status.View())
		sections = append(sections, m.input.View())

	case StateIdle:
		sections = append(sections, m.chat.View())
		if m.tasks.HasTasks() {
			sections = append(sections, m.tasks.View())
		}
		sections = append(sections, m.status.View())
		sections = append(sections, m.input.View())

	case StateProcessing:
		sections = append(sections, m.chat.View())
		if m.tasks.HasTasks() {
			sections = append(sections, m.tasks.View())
		}
		if m.agents.IsActive() {
			sections = append(sections, m.agents.View())
		}
		sections = append(sections, m.activity.View())
		sections = append(sections, m.status.View())

	case StatePlanReview:
		sections = append(sections, m.chat.View())
		sections = append(sections, m.plan.View())
		sections = append(sections, m.status.View())
	}

	if m.confirmQuit {
		sections = append(sections, "\n  Press Ctrl+C again to quit, or any key to cancel.")
	}

	return strings.Join(sections, "\n")
}

// -- Key handling --

func (m Model) handleKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	if m.confirmQuit {
		if key.Matches(k, m.keys.Cancel) {
			m.closeSSE()
			return m, tea.Quit
		}
		m.confirmQuit = false
		return m, nil
	}

	switch m.state {
	case StateIdle:
		return m.handleIdleKey(k)
	case StateProcessing:
		return m.handleProcessingKey(k)
	case StatePlanReview:
		return m.handlePlanKey(k)
	case StateBanner:
		m.state = StateIdle
		cmd := m.input.Focus()
		return m, cmd
	}

	return m, nil
}

func (m Model) handleIdleKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch {
	case key.Matches(k, m.keys.Cancel):
		if m.input.Value() == "" {
			m.confirmQuit = true
			return m, nil
		}
		m.input.Reset()
		return m, nil

	case key.Matches(k, m.keys.QuitEOF):
		if m.input.Value() == "" {
			m.closeSSE()
			return m, tea.Quit
		}

	case key.Matches(k, m.keys.Submit):
		text := strings.TrimSpace(m.input.Value())
		if text == "" {
			return m, nil
		}
		m.input.Submit(text)
		return m.submitInput(text)

	case key.Matches(k, m.keys.ToggleBackground):
		return m, nil
	}

	// Forward to input (safe type assertion)
	updated, cmd := m.input.Update(k)
	if inp, ok := updated.(model.InputModel); ok {
		m.input = inp
	}
	return m, cmd
}

func (m Model) handleProcessingKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch {
	case key.Matches(k, m.keys.Cancel):
		m.state = StateIdle
		m.activity.Stop()
		cmd := m.input.Focus()
		m.chat.AddSystemMessage("Request cancelled.")
		return m, cmd

	case key.Matches(k, m.keys.ToggleExpand):
		m.activity.SetExpanded(!m.activity.IsExpanded())
		return m, nil

	case key.Matches(k, m.keys.ToggleBackground):
		// Save snapshot and switch to idle so user can type
		m.bgTasks = append(m.bgTasks, m.activity.Summary())
		m.prevState = m.state
		m.state = StateIdle
		cmd := m.input.Focus()
		m.chat.AddSystemMessage("Task moved to background. You'll be notified when it completes.")
		return m, cmd
	}

	if key.Matches(k, m.keys.PageUp) || key.Matches(k, m.keys.PageDown) {
		updated, cmd := m.chat.Update(k)
		if c, ok := updated.(model.ChatModel); ok {
			m.chat = c
		}
		return m, cmd
	}

	return m, nil
}

func (m Model) handlePlanKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	updated, cmd := m.plan.Update(k)
	if p, ok := updated.(model.PlanModel); ok {
		m.plan = p
	}
	return m, cmd
}

// -- Business logic --

func (m Model) submitInput(text string) (Model, tea.Cmd) {
	m.chat.AddUserMessage(text)

	switch {
	case text == "/exit" || text == "/quit":
		m.closeSSE()
		return m, tea.Quit
	case text == "/clear":
		m.chat = model.NewChat(m.width, m.chatHeight())
		return m, nil
	case text == "/help":
		m.chat.AddSystemMessage(helpText())
		return m, nil
	case strings.HasPrefix(text, "/login"):
		arg := strings.TrimSpace(strings.TrimPrefix(text, "/login"))
		return m, m.doLogin(arg)
	case strings.HasPrefix(text, "/logout"):
		return m, m.doLogout()
	}

	if strings.HasPrefix(text, "/") {
		parts := strings.SplitN(text[1:], " ", 2)
		cmd := parts[0]
		arg := ""
		if len(parts) > 1 {
			arg = parts[1]
		}
		return m, m.executeCommand(cmd, arg)
	}

	// Reset state for new request
	m.activity.Reset()
	m.activity.Start()
	m.agents.Reset()
	m.tasks.Reset()

	m.state = StateProcessing
	m.processingStart = time.Now()
	m.status.SetActive(true)
	m.input.Blur()

	return m, tea.Batch(
		m.orchestrate(text),
		m.tickCmd(),
	)
}

func (m Model) handleHealth(h msg.HealthResult) (Model, tea.Cmd) {
	if h.Err != nil {
		m.chat.AddSystemMessage(fmt.Sprintf("Backend unreachable: %v — retrying in 5s…", h.Err))
		m.state = StateConnecting
		return m, tea.Tick(5*time.Second, func(time.Time) tea.Msg {
			return retryHealth{}
		})
	}

	m.banner.SetHealth(h)
	m.state = StateBanner

	// Generate session ID and prepare SSE
	m.sessionID = fmt.Sprintf("tui_%d", time.Now().UnixNano())

	var cmds []tea.Cmd
	cmds = append(cmds, m.fetchCommands())
	cmds = append(cmds, m.fetchToolCount())

	// Start SSE if program reference is already available
	if m.program != nil {
		cmd := m.startSSE()
		if cmd != nil {
			cmds = append(cmds, cmd)
		}
	}

	return m, tea.Batch(cmds...)
}

func (m Model) handleOrchestrate(r msg.OrchestrateResult) (Model, tea.Cmd) {
	wasBackground := (m.state == StateIdle)

	m.activity.Stop()
	m.status.SetActive(false)
	m.state = StateIdle
	cmd := m.input.Focus()

	if r.Err != nil {
		m.chat.AddSystemMessage(fmt.Sprintf("Error: %v", r.Err))
		return m, cmd
	}

	if wasBackground {
		m.chat.AddSystemMessage("⏺ Background task completed")
	}

	m.chat.AddAgentMessage(truncateResponse(r.Output), toModelSignal(r.Signal))

	if r.Signal != nil {
		m.status.SetSignal(toModelSignal(r.Signal))
	}

	if r.SessionID != "" && m.sessionID != r.SessionID {
		m.sessionID = r.SessionID
	}

	return m, cmd
}

func (m Model) handleClientAgentResponse(r client.AgentResponseEvent) (Model, tea.Cmd) {
	if strings.Contains(r.Response, "## Plan") || strings.Contains(r.Response, "# Plan") {
		m.plan.SetPlan(r.Response)
		m.state = StatePlanReview
		return m, nil
	}

	wasBackground := (m.state == StateIdle)

	m.activity.Stop()
	m.status.SetActive(false)
	m.state = StateIdle
	cmd := m.input.Focus()

	if wasBackground {
		m.chat.AddSystemMessage("⏺ Background task completed")
	}

	sig := clientSignalToModel(r.Signal)
	m.chat.AddAgentMessage(truncateResponse(r.Response), sig)
	if sig != nil {
		m.status.SetSignal(sig)
	}
	return m, cmd
}

func (m Model) handleCommand(r msg.CommandResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemMessage(fmt.Sprintf("Command error: %v", r.Err))
		return m, nil
	}
	m.chat.AddSystemMessage(r.Output)
	return m, nil
}

func (m Model) handlePlanDecision(d model.PlanDecision) (Model, tea.Cmd) {
	m.plan.Clear()

	switch d.Decision {
	case "approve":
		m.chat.AddSystemMessage("Plan approved. Executing…")
		m.activity.Reset()
		m.activity.Start()
		m.state = StateProcessing
		m.processingStart = time.Now()
		m.status.SetActive(true)
		return m, m.orchestrate("Approved. Execute the plan.")

	case "reject":
		m.chat.AddSystemMessage("Plan rejected.")
		m.state = StateIdle
		cmd := m.input.Focus()
		return m, cmd

	case "edit":
		m.chat.AddSystemMessage("Edit mode — type your feedback.")
		m.state = StateIdle
		cmd := m.input.Focus()
		return m, cmd
	}

	m.state = StateIdle
	cmd := m.input.Focus()
	return m, cmd
}

// -- Auth commands --

func (m Model) doLogin(userID string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.Login(userID)
		if err != nil {
			return msg.LoginResult{Err: err}
		}
		// Persist token
		profileDir := profileDirPath()
		if profileDir != "" {
			os.MkdirAll(profileDir, 0755)
			os.WriteFile(filepath.Join(profileDir, "token"), []byte(resp.Token), 0600)
		}
		return msg.LoginResult{Token: resp.Token, ExpiresIn: resp.ExpiresIn}
	}
}

func (m Model) doLogout() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		err := c.Logout()
		// Remove persisted token
		profileDir := profileDirPath()
		if profileDir != "" {
			os.Remove(filepath.Join(profileDir, "token"))
		}
		return msg.LogoutResult{Err: err}
	}
}

// -- SSE lifecycle --

func (m *Model) startSSE() tea.Cmd {
	if m.program == nil || m.sessionID == "" {
		return nil
	}
	m.sse = client.NewSSE(m.client.BaseURL, m.client.Token, m.sessionID)
	return m.sse.ListenCmd(m.program)
}

func (m *Model) closeSSE() {
	if m.sse != nil {
		m.sse.Close()
		m.sse = nil
	}
}

// -- Commands (tea.Cmd factories) --

func (m Model) checkHealth() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		health, err := c.Health()
		if err != nil {
			return msg.HealthResult{Err: err}
		}
		return msg.HealthResult{
			Status:        health.Status,
			Version:       health.Version,
			UptimeSeconds: health.UptimeSeconds,
			Provider:      health.Provider,
		}
	}
}

func (m Model) orchestrate(input string) tea.Cmd {
	c := m.client
	sid := m.sessionID
	return func() tea.Msg {
		resp, err := c.Orchestrate(client.OrchestrateRequest{
			Input:     input,
			SessionID: sid,
		})
		if err != nil {
			return msg.OrchestrateResult{Err: err}
		}
		r := msg.OrchestrateResult{
			SessionID:      resp.SessionID,
			Output:         resp.Output,
			ToolsUsed:      resp.ToolsUsed,
			IterationCount: resp.IterationCount,
			ExecutionMs:    resp.ExecutionMs,
		}
		if resp.Signal != nil {
			r.Signal = &msg.Signal{
				Mode:    resp.Signal.Mode,
				Genre:   resp.Signal.Genre,
				Type:    resp.Signal.Type,
				Format:  resp.Signal.Format,
				Weight:  resp.Signal.Weight,
				Channel: resp.Signal.Channel,
			}
		}
		return r
	}
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
		return msg.CommandResult{
			Kind:   resp.Kind,
			Output: resp.Output,
			Action: resp.Action,
		}
	}
}

func (m Model) fetchCommands() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		commands, err := c.ListCommands()
		if err != nil {
			return commandsLoaded(nil)
		}
		names := make([]string, len(commands))
		for i, cmd := range commands {
			names[i] = "/" + cmd.Name
		}
		return commandsLoaded(names)
	}
}

type commandsLoaded []string

type toolCountLoaded int

type retryHealth struct{}

func (m Model) fetchToolCount() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		tools, err := c.ListTools()
		if err != nil {
			return toolCountLoaded(0)
		}
		return toolCountLoaded(len(tools))
	}
}

func (m Model) tickCmd() tea.Cmd {
	return tea.Tick(time.Second, func(time.Time) tea.Msg {
		return msg.TickMsg{}
	})
}

// -- Signal conversion helpers --

func toModelSignal(s *msg.Signal) *model.Signal {
	if s == nil {
		return nil
	}
	return &model.Signal{
		Mode:    s.Mode,
		Genre:   s.Genre,
		Type:    s.Type,
		Format:  s.Format,
		Weight:  s.Weight,
		Channel: s.Channel,
	}
}

func clientSignalToModel(s *client.Signal) *model.Signal {
	if s == nil {
		return nil
	}
	return &model.Signal{
		Mode:    s.Mode,
		Genre:   s.Genre,
		Type:    s.Type,
		Format:  s.Format,
		Weight:  s.Weight,
		Channel: s.Channel,
	}
}

// -- Layout --

func (m Model) chatHeight() int {
	reserved := 7
	h := m.height - reserved
	if h < 5 {
		h = 5
	}
	return h
}

func (m Model) renderConnecting() string {
	return lipgloss.NewStyle().
		Foreground(lipgloss.Color("#7C3AED")).
		Render("  Connecting to OSA backend…")
}

func helpText() string {
	return `Available commands:
  /help      — Show this help
  /login [id] — Authenticate with backend
  /logout    — End session and clear token
  /status    — System status
  /model     — Current model info
  /models    — List available models
  /agents    — List agent roster
  /tools     — List available tools
  /usage     — Token usage breakdown
  /compact   — Context compaction
  /clear     — Clear chat history
  /exit      — Exit OSA

Keys:
  Ctrl+O     — Expand/collapse tool details
  Ctrl+B     — Background current task
  Ctrl+C     — Cancel request / quit
  Ctrl+D     — Quit (empty input)`
}
