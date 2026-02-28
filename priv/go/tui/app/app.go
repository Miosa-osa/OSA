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
	"github.com/miosa/osa-tui/style"
)

var ProfileDir string

func profileDirPath() string { return ProfileDir }

const maxMessageSize = 100_000

func truncateResponse(s string) string {
	if len(s) > maxMessageSize {
		return s[:maxMessageSize] + "\n\n... (response truncated at 100KB)"
	}
	return s
}

type ProgramReady struct{ Program *tea.Program }
type bannerTimeout struct{}
type commandsLoaded []string
type toolCountLoaded int
type retryHealth struct{}

type Model struct {
	banner          model.BannerModel
	chat            model.ChatModel
	input           model.InputModel
	activity        model.ActivityModel
	tasks           model.TasksModel
	status          model.StatusModel
	plan            model.PlanModel
	agents          model.AgentsModel
	state           State
	client          *client.Client
	sse             *client.SSEClient
	program         *tea.Program
	sessionID       string
	width           int
	height          int
	keys            KeyMap
	bgTasks         []string
	confirmQuit     bool
	processingStart time.Time
}

func New(c *client.Client) Model {
	workspace, _ := os.Getwd()
	banner := model.NewBanner()
	banner.SetWorkspace(workspace)
	return Model{
		banner: banner, chat: model.NewChat(80, 20), input: model.NewInput(),
		activity: model.NewActivity(), tasks: model.NewTasks(), status: model.NewStatus(),
		plan: model.NewPlan(), agents: model.NewAgents(), state: StateConnecting,
		client: c, keys: DefaultKeyMap(), width: 80, height: 24,
	}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(m.checkHealth(), m.input.Init(), m.activity.Init(), tea.WindowSize())
}

func (m Model) Update(rawMsg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd
	switch v := rawMsg.(type) {
	case tea.WindowSizeMsg:
		m.width = v.Width
		m.height = v.Height
		m.chat.SetSize(v.Width, m.chatHeight())
		m.plan.SetWidth(v.Width - 4)
		m.input.SetWidth(v.Width)
		m.banner.SetWidth(v.Width)
		return m, nil
	case tea.KeyMsg:
		return m.handleKey(v)
	case ProgramReady:
		m.program = v.Program
		if m.sessionID != "" && m.sse == nil {
			return m, m.startSSE()
		}
		return m, nil
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
		// Refresh welcome screen with updated tool count
		m.chat.SetWelcomeData(m.banner.Version(), m.banner.WelcomeLine(), m.banner.Workspace())
		return m, nil
	case client.SSEConnectedEvent:
		m.sessionID = v.SessionID
		return m, nil
	case client.SSEDisconnectedEvent:
		if m.sessionID != "" && m.sse != nil && !m.sse.IsClosed() && m.program != nil {
			return m, m.sse.ReconnectListenCmd(m.program)
		}
		return m, nil
	case client.SSEAuthFailedEvent:
		m.chat.AddSystemWarning("Authentication expired. Use /login to re-authenticate.")
		m.closeSSE()
		m.state = StateIdle
		return m, m.input.Focus()
	case msg.LoginResult:
		if v.Err != nil {
			m.chat.AddSystemError(fmt.Sprintf("Login failed: %v", v.Err))
		} else {
			m.chat.AddSystemMessage(fmt.Sprintf("Authenticated (token expires in %ds)", v.ExpiresIn))
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
			m.chat.AddSystemError(fmt.Sprintf("Logout error: %v", v.Err))
		} else {
			m.chat.AddSystemMessage("Logged out")
			m.closeSSE()
		}
		return m, nil
	case retryHealth:
		return m, m.checkHealth()
	case bannerTimeout:
		if m.state == StateBanner {
			m.state = StateIdle
			m.chat.SetSize(m.width, m.chatHeight())
			return m, m.input.Focus()
		}
		return m, nil
	case client.AgentResponseEvent:
		return m.handleClientAgentResponse(v)
	case client.LLMRequestEvent:
		m.activity, _ = m.activity.Update(msg.LLMRequest{Iteration: v.Iteration})
		return m, nil
	case client.ToolCallStartEvent:
		m.activity, _ = m.activity.Update(msg.ToolCallStart{Name: v.Name, Args: v.Args})
		return m, nil
	case client.ToolCallEndEvent:
		m.activity, _ = m.activity.Update(msg.ToolCallEnd{Name: v.Name, DurationMs: v.DurationMs, Success: v.Success})
		return m, nil
	case client.LLMResponseEvent:
		m.activity, _ = m.activity.Update(msg.LLMResponse{DurationMs: v.DurationMs, InputTokens: v.InputTokens, OutputTokens: v.OutputTokens})
		m.status.SetStats(time.Since(m.processingStart), m.activity.ToolCount(), v.InputTokens, v.OutputTokens)
		return m, nil
	case client.ContextPressureEvent:
		m.status.SetContext(v.Utilization, v.MaxTokens, v.EstimatedTokens)
		return m, nil
	case client.OrchestratorTaskStartedEvent:
		m.agents.Start()
		return m, nil
	case client.OrchestratorWaveStartedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorWaveStarted{WaveNumber: v.WaveNumber, TotalWaves: v.TotalWaves})
		return m, nil
	case client.OrchestratorAgentStartedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentStarted{AgentName: v.AgentName, Role: v.Role, Model: v.Model})
		return m, nil
	case client.OrchestratorAgentProgressEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentProgress{AgentName: v.AgentName, CurrentAction: v.CurrentAction, ToolUses: v.ToolUses, TokensUsed: v.TokensUsed})
		return m, nil
	case client.OrchestratorAgentCompletedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentCompleted{AgentName: v.AgentName, ToolUses: v.ToolUses, TokensUsed: v.TokensUsed})
		return m, nil
	case client.OrchestratorAgentFailedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentFailed{AgentName: v.AgentName, Error: v.Error, ToolUses: v.ToolUses, TokensUsed: v.TokensUsed})
		return m, nil
	case client.OrchestratorTaskCompletedEvent:
		m.agents.Stop()
		return m, nil
	case msg.ToggleExpand:
		m.activity, _ = m.activity.Update(v)
		m.agents, _ = m.agents.Update(v)
		if updated, _ := m.tasks.Update(v); updated != nil {
			if t, ok := updated.(model.TasksModel); ok {
				m.tasks = t
			}
		}
		return m, nil
	case msg.TickMsg:
		if m.state == StateProcessing {
			m.status.SetStats(time.Since(m.processingStart), m.activity.ToolCount(), m.activity.InputTokens(), m.activity.OutputTokens())
			cmds = append(cmds, m.tickCmd())
		}
		var cmd tea.Cmd
		m.activity, cmd = m.activity.Update(rawMsg)
		cmds = append(cmds, cmd)
		return m, tea.Batch(cmds...)
	case model.PlanDecision:
		return m.handlePlanDecision(v)
	}
	if m.state == StateProcessing {
		var cmd tea.Cmd
		m.activity, cmd = m.activity.Update(rawMsg)
		cmds = append(cmds, cmd)
	}
	return m, tea.Batch(cmds...)
}

func (m Model) View() string {
	var sections []string
	switch m.state {
	case StateConnecting:
		sections = append(sections, m.renderConnecting())
	case StateBanner:
		sections = append(sections, m.banner.ViewFull())
		sections = append(sections, "")
		sections = append(sections, m.input.View())
	case StateIdle:
		sections = append(sections, m.banner.HeaderView())
		sections = append(sections, m.chat.View())
		if m.tasks.HasTasks() {
			sections = append(sections, m.tasks.View())
		}
		sections = append(sections, m.status.View())
		sections = append(sections, m.input.View())
	case StateProcessing:
		// Recalculate chat height dynamically as activity/agents panels change size
		m.chat.SetSize(m.width, m.chatHeight())
		sections = append(sections, m.banner.HeaderView())
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
		sections = append(sections, m.banner.HeaderView())
		sections = append(sections, m.chat.View())
		sections = append(sections, m.plan.View())
		sections = append(sections, m.status.View())
	}
	if m.confirmQuit {
		sections = append(sections, "\n  Press Ctrl+C again to quit, or any key to cancel.")
	}
	return strings.Join(sections, "\n")
}

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
		return m, m.input.Focus()
	}
	return m, nil
}

func (m Model) handleIdleKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch {
	case key.Matches(k, m.keys.Escape):
		m.input.Reset()
		return m, nil
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
	case key.Matches(k, m.keys.PageUp), key.Matches(k, m.keys.PageDown):
		updated, cmd := m.chat.Update(k)
		if c, ok := updated.(model.ChatModel); ok {
			m.chat = c
		}
		return m, cmd
	}
	updated, cmd := m.input.Update(k)
	if inp, ok := updated.(model.InputModel); ok {
		m.input = inp
	}
	return m, cmd
}

func (m Model) handleProcessingKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch {
	case key.Matches(k, m.keys.Cancel), key.Matches(k, m.keys.Escape):
		m.state = StateIdle
		m.activity.Stop()
		m.status.SetActive(false)
		m.chat.AddSystemMessage("Request cancelled.")
		return m, m.input.Focus()
	case key.Matches(k, m.keys.ToggleExpand):
		m.activity.SetExpanded(!m.activity.IsExpanded())
		return m, nil
	case key.Matches(k, m.keys.ToggleBackground):
		m.bgTasks = append(m.bgTasks, m.activity.Summary())
		m.state = StateIdle
		m.chat.AddSystemMessage("Task moved to background.")
		return m, m.input.Focus()
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
		return m, m.doLogin(strings.TrimSpace(strings.TrimPrefix(text, "/login")))
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
	m.activity.Reset()
	m.activity.Start()
	m.agents.Reset()
	m.tasks.Reset()
	m.state = StateProcessing
	m.processingStart = time.Now()
	m.status.SetActive(true)
	m.input.Blur()
	return m, tea.Batch(m.orchestrate(text), m.tickCmd())
}

func (m Model) handleHealth(h msg.HealthResult) (Model, tea.Cmd) {
	if h.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Backend unreachable: %v -- retrying in 5s", h.Err))
		m.state = StateConnecting
		return m, tea.Tick(5*time.Second, func(time.Time) tea.Msg { return retryHealth{} })
	}
	m.banner.SetHealth(h)
	m.status.SetProviderInfo(h.Provider, h.Model)
	m.state = StateIdle
	m.sessionID = fmt.Sprintf("tui_%d", time.Now().UnixNano())

	// Populate welcome screen data (shown in chat viewport when no messages)
	m.chat.SetWelcomeData(m.banner.Version(), m.banner.WelcomeLine(), m.banner.Workspace())
	m.chat.SetSize(m.width, m.chatHeight())

	var cmds []tea.Cmd
	cmds = append(cmds, m.fetchCommands(), m.fetchToolCount(), m.input.Focus())
	if m.program != nil {
		if cmd := m.startSSE(); cmd != nil {
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
	var cmds []tea.Cmd
	cmds = append(cmds, m.input.Focus())
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Error: %v", r.Err))
		return m, tea.Batch(cmds...)
	}
	if wasBackground {
		m.chat.AddSystemMessage("Background task completed")
	}
	output := truncateResponse(r.Output)
	if output == "" {
		output = "(no response)"
	}
	m.chat.AddAgentMessage(output, toModelSignal(r.Signal), r.ExecutionMs, m.banner.ModelName())
	if r.Signal != nil {
		m.status.SetSignal(toModelSignal(r.Signal))
	}
	// Update session ID from backend response
	if r.SessionID != "" && m.sessionID != r.SessionID {
		m.sessionID = r.SessionID
	}
	// Start SSE if not connected yet (session now exists server-side)
	if m.sse == nil && m.program != nil && m.sessionID != "" {
		if cmd := m.startSSE(); cmd != nil {
			cmds = append(cmds, cmd)
		}
	}
	return m, tea.Batch(cmds...)
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
		m.chat.AddSystemMessage("Background task completed")
	}
	sig := clientSignalToModel(r.Signal)
	m.chat.AddAgentMessage(truncateResponse(r.Response), sig, time.Since(m.processingStart).Milliseconds(), m.banner.ModelName())
	if sig != nil {
		m.status.SetSignal(sig)
	}
	return m, cmd
}

func (m Model) handleCommand(r msg.CommandResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Command error: %v", r.Err))
		return m, nil
	}
	m.chat.AddSystemMessage(r.Output)
	return m, nil
}

func (m Model) handlePlanDecision(d model.PlanDecision) (Model, tea.Cmd) {
	m.plan.Clear()
	switch d.Decision {
	case "approve":
		m.chat.AddSystemMessage("Plan approved. Executing...")
		m.activity.Reset()
		m.activity.Start()
		m.state = StateProcessing
		m.processingStart = time.Now()
		m.status.SetActive(true)
		return m, m.orchestrate("Approved. Execute the plan.")
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

func (m Model) doLogin(userID string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.Login(userID)
		if err != nil {
			return msg.LoginResult{Err: err}
		}
		pd := profileDirPath()
		if pd != "" {
			os.MkdirAll(pd, 0755)
			os.WriteFile(filepath.Join(pd, "token"), []byte(resp.Token), 0600)
		}
		return msg.LoginResult{Token: resp.Token, ExpiresIn: resp.ExpiresIn}
	}
}

func (m Model) doLogout() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		err := c.Logout()
		pd := profileDirPath()
		if pd != "" {
			os.Remove(filepath.Join(pd, "token"))
		}
		return msg.LogoutResult{Err: err}
	}
}

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

func (m Model) checkHealth() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		health, err := c.Health()
		if err != nil {
			return msg.HealthResult{Err: err}
		}
		return msg.HealthResult{Status: health.Status, Version: health.Version, Provider: health.Provider, Model: health.Model}
	}
}

func (m Model) orchestrate(input string) tea.Cmd {
	c := m.client
	sid := m.sessionID
	return func() tea.Msg {
		resp, err := c.Orchestrate(client.OrchestrateRequest{Input: input, SessionID: sid})
		if err != nil {
			return msg.OrchestrateResult{Err: err}
		}
		r := msg.OrchestrateResult{SessionID: resp.SessionID, Output: resp.Output, ToolsUsed: resp.ToolsUsed, IterationCount: resp.IterationCount, ExecutionMs: resp.ExecutionMs}
		if resp.Signal != nil {
			r.Signal = &msg.Signal{Mode: resp.Signal.Mode, Genre: resp.Signal.Genre, Type: resp.Signal.Type, Format: resp.Signal.Format, Weight: resp.Signal.Weight, Channel: resp.Signal.Channel}
		}
		return r
	}
}

func (m Model) executeCommand(cmd, arg string) tea.Cmd {
	c := m.client
	sid := m.sessionID
	return func() tea.Msg {
		resp, err := c.ExecuteCommand(client.CommandExecuteRequest{Command: cmd, Arg: arg, SessionID: sid})
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
		names := make([]string, len(commands))
		for i, cmd := range commands {
			names[i] = "/" + cmd.Name
		}
		return commandsLoaded(names)
	}
}

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
	return tea.Tick(time.Second, func(time.Time) tea.Msg { return msg.TickMsg{} })
}

func toModelSignal(s *msg.Signal) *model.Signal {
	if s == nil {
		return nil
	}
	return &model.Signal{Mode: s.Mode, Genre: s.Genre, Type: s.Type, Format: s.Format, Weight: s.Weight, Channel: s.Channel}
}

func clientSignalToModel(s *client.Signal) *model.Signal {
	if s == nil {
		return nil
	}
	return &model.Signal{Mode: s.Mode, Genre: s.Genre, Type: s.Type, Format: s.Format, Weight: s.Weight, Channel: s.Channel}
}

// chatHeight calculates available lines for the chat viewport based on current state.
func (m Model) chatHeight() int {
	reserved := 2 // header + separator
	statusView := m.status.View()
	if statusView != "" {
		reserved += countLines(statusView)
	} else {
		reserved += 1
	}
	if m.state != StatePlanReview {
		reserved += 2 // input separator + prompt line
	}

	if m.state == StateProcessing {
		reserved += countLines(m.activity.View())
		if m.agents.IsActive() {
			reserved += countLines(m.agents.View())
		}
	}
	if m.tasks.HasTasks() {
		reserved += countLines(m.tasks.View())
	}

	h := m.height - reserved
	if h < 5 {
		h = 5
	}
	return h
}

// countLines returns the number of lines in a rendered string.
func countLines(s string) int {
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}

// renderConnecting shows the ASCII logo with a connecting message.
func (m Model) renderConnecting() string {
	logoStyle := lipgloss.NewStyle().Foreground(style.Primary)
	logo := logoStyle.Render(model.OsaLogo)
	label := style.BannerTitle.Render("  Connecting to OSA backend...")
	return logo + "\n\n" + label
}

func helpText() string {
	return "Available commands:\n" +
		"  /help       Show this help\n" +
		"  /status     System status\n" +
		"  /model      Current model info\n" +
		"  /models     List available models\n" +
		"  /agents     List agent roster\n" +
		"  /tools      List available tools\n" +
		"  /clear      Clear chat history\n" +
		"  /exit       Exit OSA\n" +
		"\nKeys:\n" +
		"  ESC         Cancel / clear input\n" +
		"  Ctrl+C      Cancel / quit\n" +
		"  Ctrl+O      Expand/collapse details\n" +
		"  Ctrl+B      Background current task\n" +
		"  PgUp/PgDn   Scroll chat history\n" +
		"  Tab         Autocomplete commands"
}
