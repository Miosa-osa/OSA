package app

import (
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/config"
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

// knownProviders mirrors the backend's 18-provider registry (registry.ex).
var knownProviders = map[string]bool{
	"ollama": true, "anthropic": true, "openai": true, "groq": true,
	"together": true, "fireworks": true, "deepseek": true, "perplexity": true,
	"mistral": true, "replicate": true, "openrouter": true, "google": true,
	"cohere": true, "qwen": true, "moonshot": true, "zhipu": true,
	"volcengine": true, "baichuan": true,
}

func isKnownProvider(name string) bool {
	return knownProviders[strings.ToLower(name)]
}

type ProgramReady struct{ Program *tea.Program }
type bannerTimeout struct{}
type commandsLoaded []client.CommandEntry
type toolCountLoaded int
type retryHealth struct{}

type Model struct {
	banner                model.BannerModel
	chat                  model.ChatModel
	input                 model.InputModel
	activity              model.ActivityModel
	tasks                 model.TasksModel
	status                model.StatusModel
	plan                  model.PlanModel
	agents                model.AgentsModel
	picker                model.PickerModel
	toasts                model.ToastsModel
	palette               model.PaletteModel
	state                 State
	client                *client.Client
	sse                   *client.SSEClient
	program               *tea.Program
	sessionID             string
	width                 int
	height                int
	keys                  KeyMap
	bgTasks               []string
	commandEntries        []client.CommandEntry
	confirmQuit           bool
	processingStart       time.Time
	streamBuf             strings.Builder
	sseReconnecting       bool   // true while a ReconnectListenCmd goroutine is in-flight
	responseReceived      bool   // true when SSE agent_response already rendered for current request
	cancelled             bool   // true when user cancelled the current request (Ctrl+C)
	pendingProviderFilter string // set by "/model <provider>" to filter picker
	config                config.Config
	refreshToken          string
}

func New(c *client.Client) Model {
	workspace, _ := os.Getwd()
	banner := model.NewBanner()
	banner.SetWorkspace(workspace)

	cfg := config.Load(profileDirPath())
	if cfg.Theme != "" {
		style.SetTheme(cfg.Theme)
	}

	return Model{
		banner: banner, chat: model.NewChat(80, 20), input: model.NewInput(),
		activity: model.NewActivity(), tasks: model.NewTasks(), status: model.NewStatus(),
		plan: model.NewPlan(), agents: model.NewAgents(), picker: model.NewPicker(),
		toasts: model.NewToasts(), palette: model.NewPalette(),
		state:  StateConnecting,
		client: c, keys: DefaultKeyMap(), width: 80, height: 24,
		config: cfg,
	}
}

// SetRefreshToken sets the refresh token to use for automatic token renewal.
func (m *Model) SetRefreshToken(t string) { m.refreshToken = t }

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
		m.picker.SetWidth(v.Width - 4)
		m.input.SetWidth(v.Width)
		m.banner.SetWidth(v.Width)
		return m, nil
	case tea.MouseMsg:
		switch m.state {
		case StateIdle, StateProcessing, StatePlanReview:
			updated, cmd := m.chat.Update(v)
			if c, ok := updated.(model.ChatModel); ok {
				m.chat = c
			}
			return m, cmd
		case StateModelPicker:
			updated, cmd := m.picker.Update(v)
			if p, ok := updated.(model.PickerModel); ok {
				m.picker = p
			}
			return m, cmd
		}
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
		m.commandEntries = []client.CommandEntry(v)
		names := make([]string, len(v))
		for i, cmd := range v {
			names[i] = "/" + cmd.Name
		}
		m.input.SetCommands(names)
		return m, nil
	case toolCountLoaded:
		m.banner.SetToolCount(int(v))
		// Refresh welcome screen with updated tool count
		m.chat.SetWelcomeData(m.banner.Version(), m.banner.WelcomeLine(), m.banner.Workspace())
		return m, nil
	case client.SSEConnectedEvent:
		m.sessionID = v.SessionID
		m.sseReconnecting = false
		return m, nil
	case client.SSEDisconnectedEvent:
		if m.sseReconnecting {
			// A reconnect goroutine is already running — ignore duplicate disconnect events.
			return m, nil
		}
		if m.sessionID != "" && m.sse != nil && !m.sse.IsClosed() && m.program != nil {
			m.sseReconnecting = true
			return m, m.sse.ReconnectListenCmd(m.program)
		}
		return m, nil
	case client.SSEReconnectingEvent:
		m.chat.AddSystemWarning(fmt.Sprintf("Connection lost. Reconnecting (attempt %d/%d)...", v.Attempt, client.MaxReconnects))
		return m, nil
	case client.SSEAuthFailedEvent:
		m.closeSSE()
		if m.refreshToken != "" {
			return m, m.doRefreshToken(m.refreshToken)
		}
		m.chat.AddSystemWarning("Authentication expired. Use /login to re-authenticate.")
		m.state = StateIdle
		return m, m.input.Focus()
	case refreshTokenResult:
		return m.handleRefreshTokenResult(v)
	case msg.LoginResult:
		if v.Err != nil {
			m.chat.AddSystemError(fmt.Sprintf("Login failed: %v", v.Err))
		} else {
			m.refreshToken = v.RefreshToken
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
	case msg.SessionListResult:
		return m.handleSessionList(v)
	case msg.SessionSwitchResult:
		return m.handleSessionSwitch(v)
	case retryHealth:
		return m, m.checkHealth()
	case bannerTimeout:
		if m.state == StateBanner {
			m.state = StateIdle
			m.chat.SetSize(m.width, m.chatHeight())
			return m, m.input.Focus()
		}
		return m, nil
	case client.StreamingTokenEvent:
		m.streamBuf.WriteString(v.Text)
		m.chat.SetStreamingContent(m.streamBuf.String())
		return m, nil
	case client.ThinkingDeltaEvent:
		m.activity, _ = m.activity.Update(msg.ThinkingDelta{Text: v.Text})
		return m, nil
	case client.AgentResponseEvent:
		m.streamBuf.Reset()
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
	case client.TaskCreatedEvent:
		m.tasks.AddTask(model.Task{ID: v.TaskID, Subject: v.Subject, Status: "pending", ActiveForm: v.ActiveForm})
		return m, nil
	case client.TaskUpdatedEvent:
		m.tasks.UpdateTask(v.TaskID, v.Status)
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
	case client.SwarmStartedEvent:
		m.chat.AddSystemMessage(fmt.Sprintf("Swarm launched: %s pattern with %d agents", v.Pattern, v.AgentCount))
		return m, nil
	case client.SwarmCompletedEvent:
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.state = StateIdle
		if v.ResultPreview != "" {
			m.chat.AddAgentMessage(v.ResultPreview, nil, 0, fmt.Sprintf("swarm/%s", v.Pattern))
		} else {
			m.chat.AddSystemMessage(fmt.Sprintf("Swarm %s (%s) completed.", v.SwarmID, v.Pattern))
		}
		return m, m.input.Focus()
	case client.SwarmFailedEvent:
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.state = StateIdle
		m.chat.AddSystemError(fmt.Sprintf("Swarm %s failed: %s", v.SwarmID, v.Reason))
		return m, m.input.Focus()
	case client.SwarmCancelledEvent:
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.state = StateIdle
		m.chat.AddSystemWarning(fmt.Sprintf("Swarm %s was cancelled.", v.SwarmID))
		return m, m.input.Focus()
	case client.SwarmTimeoutEvent:
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.state = StateIdle
		m.chat.AddSystemError(fmt.Sprintf("Swarm %s timed out.", v.SwarmID))
		return m, m.input.Focus()
	case client.SwarmIntelligenceStartedEvent:
		m.chat.AddSystemMessage(fmt.Sprintf("Swarm intelligence (%s) started: %s", v.Type, v.Task))
		return m, nil
	case client.SwarmIntelligenceRoundEvent:
		m.chat.AddSystemMessage(fmt.Sprintf("Swarm intelligence round %d", v.Round))
		return m, nil
	case client.SwarmIntelligenceConvergedEvent:
		m.chat.AddSystemMessage(fmt.Sprintf("Swarm intelligence converged at round %d", v.Round))
		return m, nil
	case client.SwarmIntelligenceCompletedEvent:
		status := "completed"
		if v.Converged {
			status = "converged"
		}
		m.chat.AddSystemMessage(fmt.Sprintf("Swarm intelligence %s after %d rounds", status, v.Rounds))
		return m, nil
	case client.HookBlockedEvent:
		m.chat.AddSystemError(fmt.Sprintf("Blocked by %s: %s", v.HookName, v.Reason))
		return m, nil
	case client.BudgetWarningEvent:
		m.chat.AddSystemWarning(fmt.Sprintf("Budget at %.0f%%: %s", v.Utilization*100, v.Message))
		return m, nil
	case client.BudgetExceededEvent:
		m.chat.AddSystemError(fmt.Sprintf("Budget exceeded: %s", v.Message))
		return m, nil
	case client.ToolResultEvent:
		m.activity, _ = m.activity.Update(msg.ToolResult{Name: v.Name, Result: v.Result, Success: v.Success})
		if v.Result != "" {
			preview := v.Result
			if len(preview) > 200 {
				preview = preview[:200] + "…"
			}
			m.chat.AddSystemMessage(fmt.Sprintf("[%s] %s", v.Name, preview))
		}
		return m, nil
	case client.SignalClassifiedEvent:
		m.status.SetSignal(&model.Signal{Mode: v.Mode, Genre: v.Genre, Type: v.Type, Weight: v.Weight})
		return m, nil
	case client.SSEParseWarning:
		m.toasts.Add(v.Message, model.ToastWarning)
		return m, m.tickCmd()
	case msg.SSEParseWarning:
		m.toasts.Add(v.Message, model.ToastWarning)
		return m, m.tickCmd()
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
		m.toasts.Tick()
		needTick := false
		if m.state == StateProcessing {
			m.status.SetStats(time.Since(m.processingStart), m.activity.ToolCount(), m.activity.InputTokens(), m.activity.OutputTokens())
			// Resize chat for dynamic content height and push activity view inline
			m.chat.SetSize(m.width, m.chatHeight())
			m.chat.SetProcessingView(m.activity.View())
			needTick = true
		}
		if m.toasts.HasToasts() {
			needTick = true
		}
		m.activity, _ = m.activity.Update(rawMsg)
		if needTick {
			cmds = append(cmds, m.tickCmd())
		}
		return m, tea.Batch(cmds...)
	case model.PlanDecision:
		return m.handlePlanDecision(v)
	case msg.ModelListResult:
		return m.handleModelList(v)
	case msg.ModelSwitchResult:
		return m.handleModelSwitch(v)
	case model.PickerChoice:
		return m.handlePickerChoice(v)
	case model.PickerCancel:
		m.picker.Clear()
		m.state = StateIdle
		return m, m.input.Focus()
	case model.PaletteExecuteMsg:
		m.state = StateIdle
		return m.submitInput(v.Command)
	case model.PaletteDismissMsg:
		m.state = StateIdle
		return m, m.input.Focus()
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
		if m.chat.HasMessages() {
			sections = append(sections, m.chat.View())
			if m.tasks.HasTasks() {
				sections = append(sections, m.tasks.View())
			}
			sections = append(sections, m.status.View())
		} else {
			sections = append(sections, m.chat.WelcomeView())
		}
		sections = append(sections, m.input.View())
	case StateProcessing:
		// Activity view is rendered inline in the chat viewport (via SetProcessingView)
		sections = append(sections, m.banner.HeaderView())
		sections = append(sections, m.chat.View())
		if m.tasks.HasTasks() {
			sections = append(sections, m.tasks.View())
		}
		if m.agents.IsActive() {
			sections = append(sections, m.agents.View())
		}
		sections = append(sections, m.status.View())
	case StatePlanReview:
		sections = append(sections, m.banner.HeaderView())
		sections = append(sections, m.chat.View())
		sections = append(sections, m.plan.View())
		sections = append(sections, m.status.View())
	case StateModelPicker:
		sections = append(sections, m.banner.HeaderView())
		if m.chat.HasMessages() {
			sections = append(sections, m.chat.View())
		}
		sections = append(sections, m.picker.View())
	case StatePalette:
		if m.palette.IsActive() {
			return m.palette.View()
		}
	}
	if m.toasts.HasToasts() {
		sections = append(sections, m.toasts.View(m.width))
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
	case StateModelPicker:
		return m.handlePickerKey(k)
	case StatePalette:
		return m.handlePaletteKey(k)
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
	case key.Matches(k, m.keys.Help):
		m.chat.AddSystemMessage(m.dynamicHelpText())
		return m, nil
	case key.Matches(k, m.keys.NewSession):
		return m, m.createSession()
	case key.Matches(k, m.keys.ScrollTop):
		m.chat.ScrollToTop()
		return m, nil
	case key.Matches(k, m.keys.ScrollBottom):
		m.chat.ScrollToBottom()
		return m, nil
	case key.Matches(k, m.keys.ClearInput):
		m.input.ClearInput()
		return m, nil
	case key.Matches(k, m.keys.Palette):
		return m.openPalette()
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
		m.cancelled = true
		m.state = StateIdle
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.chat.AddSystemMessage("Request cancelled.")
		return m, m.input.Focus()
	case key.Matches(k, m.keys.ToggleExpand):
		m.activity.SetExpanded(!m.activity.IsExpanded())
		return m, nil
	case key.Matches(k, m.keys.ToggleBackground):
		m.bgTasks = append(m.bgTasks, m.activity.Summary())
		m.status.SetBackgroundCount(len(m.bgTasks))
		m.state = StateIdle
		m.chat.ClearProcessingView()
		m.toasts.Add("Task moved to background", model.ToastInfo)
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

func (m Model) handlePickerKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Ctrl+C in picker emits PickerCancel (same path as Esc)
	if key.Matches(k, m.keys.Cancel) {
		m.picker.Clear()
		return m, func() tea.Msg { return model.PickerCancel{} }
	}
	updated, cmd := m.picker.Update(k)
	if p, ok := updated.(model.PickerModel); ok {
		m.picker = p
	}
	return m, cmd
}

func (m Model) openPalette() (Model, tea.Cmd) {
	// Build palette items from command entries + local commands
	var items []model.PaletteItem

	// Local-only commands first
	localCmds := []model.PaletteItem{
		{Name: "/help", Description: "Show available commands", Category: "system"},
		{Name: "/clear", Description: "Clear chat history", Category: "system"},
		{Name: "/theme", Description: "List or switch themes", Category: "system"},
		{Name: "/models", Description: "Browse & switch models", Category: "config"},
		{Name: "/sessions", Description: "List all sessions", Category: "session"},
		{Name: "/session new", Description: "Create new session", Category: "session"},
		{Name: "/bg", Description: "List background tasks", Category: "system"},
		{Name: "/exit", Description: "Exit OSA", Category: "system"},
	}
	items = append(items, localCmds...)

	// Backend commands (skip duplicates)
	seen := make(map[string]bool)
	for _, lc := range localCmds {
		seen[lc.Name] = true
	}
	for _, cmd := range m.commandEntries {
		name := "/" + cmd.Name
		if !seen[name] {
			items = append(items, model.PaletteItem{
				Name:        name,
				Description: cmd.Description,
				Category:    cmd.Category,
			})
		}
	}

	m.state = StatePalette
	m.input.Blur()
	cmd := m.palette.Open(items, m.width, m.height)
	return m, cmd
}

func (m Model) handlePaletteKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	m.palette, cmd = m.palette.Update(k)
	return m, cmd
}

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
		m.chat = model.NewChat(m.width, m.chatHeight())
		m.chat.SetWelcomeData(m.banner.Version(), m.banner.WelcomeLine(), m.banner.Workspace())
		return m, nil
	case strings.HasPrefix(text, "/login"):
		m.toasts.Add("Authenticating...", model.ToastInfo)
		return m, tea.Batch(m.doLogin(strings.TrimSpace(strings.TrimPrefix(text, "/login"))), m.tickCmd())
	case strings.HasPrefix(text, "/logout"):
		m.toasts.Add("Logging out...", model.ToastInfo)
		return m, tea.Batch(m.doLogout(), m.tickCmd())
	case text == "/sessions":
		m.toasts.Add("Loading sessions...", model.ToastInfo)
		return m, tea.Batch(m.listSessions(), m.tickCmd())
	case text == "/session" || strings.HasPrefix(text, "/session "):
		arg := strings.TrimSpace(strings.TrimPrefix(text, "/session"))
		if arg == "" {
			m.chat.AddSystemMessage("Current session: " + shortID(m.sessionID))
			return m, nil
		}
		if arg == "new" {
			m.toasts.Add("Creating session...", model.ToastInfo)
			return m, tea.Batch(m.createSession(), m.tickCmd())
		}
		m.toasts.Add(fmt.Sprintf("Switching to session %s...", arg), model.ToastInfo)
		return m, tea.Batch(m.switchSession(arg), m.tickCmd())
	case text == "/models":
		m.toasts.Add("Loading models...", model.ToastInfo)
		m.input.Blur()
		return m, tea.Batch(m.fetchModels(), m.tickCmd())
	case text == "/model":
		// Open picker filtered to current provider for quick switching
		m.pendingProviderFilter = strings.ToLower(m.banner.Provider())
		m.toasts.Add(fmt.Sprintf("Loading %s models...", m.banner.Provider()), model.ToastInfo)
		m.input.Blur()
		return m, tea.Batch(m.fetchModels(), m.tickCmd())
	case strings.HasPrefix(text, "/model "):
		arg := strings.TrimSpace(strings.TrimPrefix(text, "/model"))
		parts := strings.SplitN(arg, "/", 2)
		if len(parts) == 2 {
			// "/model provider/name" → direct switch
			m.chat.AddSystemMessage(fmt.Sprintf("Switching to %s / %s...", parts[0], parts[1]))
			return m, m.switchModel(parts[0], parts[1])
		}
		if isKnownProvider(arg) {
			// "/model anthropic" → open picker filtered to this provider
			m.pendingProviderFilter = strings.ToLower(arg)
			m.toasts.Add(fmt.Sprintf("Loading %s models...", arg), model.ToastInfo)
			m.input.Blur()
			return m, tea.Batch(m.fetchModels(), m.tickCmd())
		}
		// "/model qwen3:8b" → default to ollama
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
			m.chat.AddSystemError(fmt.Sprintf("Unknown theme: %s (available: %s)", name, strings.Join(style.ThemeNames, ", ")))
			return m, nil
		}
		m.config.Theme = name
		if err := config.Save(profileDirPath(), m.config); err != nil {
			m.chat.AddSystemWarning(fmt.Sprintf("Theme applied but could not persist: %v", err))
		}
		// Force re-render all messages with new theme colors (BUG-019).
		m.chat.SetSize(m.width, m.chatHeight())
		m.toasts.Add(fmt.Sprintf("Theme set to: %s", name), model.ToastInfo)
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
		m.toasts.Add(fmt.Sprintf("Running /%s...", cmd), model.ToastInfo)
		return m, tea.Batch(m.executeCommand(cmd, arg), m.tickCmd())
	}
	m.activity.Reset()
	m.activity.Start()
	m.agents.Reset()
	m.tasks.Reset()
	m.streamBuf.Reset()
	m.responseReceived = false
	m.cancelled = false
	m.state = StateProcessing
	m.processingStart = time.Now()
	m.status.SetActive(true)
	m.chat.SetProcessingView(m.activity.View()) // show activity inline immediately
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
	m.state = StateBanner
	b := make([]byte, 4)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		// Fallback to timestamp-only session ID
		b = []byte{0, 0, 0, 0}
	}
	m.sessionID = fmt.Sprintf("tui_%d_%x", time.Now().UnixNano(), b)

	// Populate welcome screen data (shown in chat viewport when no messages)
	m.chat.SetWelcomeData(m.banner.Version(), m.banner.WelcomeLine(), m.banner.Workspace())
	m.chat.SetSize(m.width, m.chatHeight())

	var cmds []tea.Cmd
	cmds = append(cmds, m.fetchCommands(), m.fetchToolCount())
	cmds = append(cmds, tea.Tick(2*time.Second, func(time.Time) tea.Msg { return bannerTimeout{} }))
	if m.program != nil {
		if cmd := m.startSSE(); cmd != nil {
			cmds = append(cmds, cmd)
		}
	}
	return m, tea.Batch(cmds...)
}

func (m Model) handleOrchestrate(r msg.OrchestrateResult) (Model, tea.Cmd) {
	// If user cancelled, silently drop the late-arriving response (BUG-018).
	if m.cancelled {
		if r.Err == nil && r.SessionID != "" && m.sessionID != r.SessionID {
			m.sessionID = r.SessionID
		}
		if m.sse == nil && m.program != nil && m.sessionID != "" {
			if cmd := m.startSSE(); cmd != nil {
				return m, cmd
			}
		}
		return m, nil
	}
	// If SSE already rendered this response, skip duplicate (BUG-017).
	if m.responseReceived {
		if r.SessionID != "" && m.sessionID != r.SessionID {
			m.sessionID = r.SessionID
		}
		if m.sse == nil && m.program != nil && m.sessionID != "" {
			if cmd := m.startSSE(); cmd != nil {
				return m, cmd
			}
		}
		return m, nil
	}

	wasBackground := (m.state == StateIdle)
	m.activity.Stop()
	m.chat.ClearProcessingView()
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
		if len(m.bgTasks) > 0 {
			m.bgTasks = m.bgTasks[1:]
		}
		m.status.SetBackgroundCount(len(m.bgTasks))
	}
	m.responseReceived = true
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
	// Drop if user cancelled or REST already rendered (BUG-017/018).
	if m.cancelled || m.responseReceived {
		return m, nil
	}
	if strings.Contains(r.Response, "## Plan") || strings.Contains(r.Response, "# Plan") {
		m.plan.SetPlan(r.Response)
		m.state = StatePlanReview
		return m, nil
	}
	m.responseReceived = true
	wasBackground := (m.state == StateIdle)
	m.activity.Stop()
	m.chat.ClearProcessingView()
	m.status.SetActive(false)
	m.state = StateIdle
	cmd := m.input.Focus()
	if wasBackground {
		m.chat.AddSystemMessage("Background task completed")
		if len(m.bgTasks) > 0 {
			m.bgTasks = m.bgTasks[1:]
		}
		m.status.SetBackgroundCount(len(m.bgTasks))
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
	switch r.Kind {
	case "prompt":
		// Custom commands expand to prompts — send to agent
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

func (m Model) submitPrompt(text string) (Model, tea.Cmd) {
	m.activity.Reset()
	m.activity.Start()
	m.agents.Reset()
	m.tasks.Reset()
	m.streamBuf.Reset()
	m.responseReceived = false
	m.cancelled = false
	m.state = StateProcessing
	m.processingStart = time.Now()
	m.status.SetActive(true)
	m.chat.SetProcessingView(m.activity.View())
	m.input.Blur()
	return m, tea.Batch(m.orchestrate(text), m.tickCmd())
}

func (m Model) handleCommandAction(action, output string) (Model, tea.Cmd) {
	switch {
	case action == ":new_session":
		m.closeSSE()
		b := make([]byte, 4)
		io.ReadFull(rand.Reader, b) //nolint:errcheck
		m.sessionID = fmt.Sprintf("tui_%d_%x", time.Now().UnixNano(), b)
		m.chat = model.NewChat(m.width, m.chatHeight())
		m.chat.SetWelcomeData(m.banner.Version(), m.banner.WelcomeLine(), m.banner.Workspace())
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
		m.chat = model.NewChat(m.width, m.chatHeight())
		m.chat.SetWelcomeData(m.banner.Version(), m.banner.WelcomeLine(), m.banner.Workspace())
		if output != "" {
			m.chat.AddSystemMessage(output)
		}
		return m, nil
	case strings.HasPrefix(action, "{:resume_session"):
		// Extract session ID from "{:resume_session, \"session_id\"}"
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
		// Unknown action — just show the output
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

func (m Model) handlePlanDecision(d model.PlanDecision) (Model, tea.Cmd) {
	m.plan.Clear()
	switch d.Decision {
	case "approve":
		m.chat.AddSystemMessage("Plan approved. Executing...")
		m.activity.Reset()
		m.activity.Start()
		m.streamBuf.Reset()
		m.state = StateProcessing
		m.processingStart = time.Now()
		m.status.SetActive(true)
		return m, tea.Batch(m.orchestrate("Approved. Execute the plan."), m.tickCmd())
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
			if err := os.MkdirAll(pd, 0755); err != nil {
				return msg.LoginResult{Err: fmt.Errorf("create profile dir: %w", err)}
			}
			if err := os.WriteFile(filepath.Join(pd, "token"), []byte(resp.Token), 0600); err != nil {
				return msg.LoginResult{Token: resp.Token, Err: fmt.Errorf("save token: %w", err)}
			}
			if resp.RefreshToken != "" {
				_ = os.WriteFile(filepath.Join(pd, "refresh_token"), []byte(resp.RefreshToken), 0600)
			}
		}
		return msg.LoginResult{Token: resp.Token, RefreshToken: resp.RefreshToken, ExpiresIn: resp.ExpiresIn}
	}
}

// refreshTokenResult is the internal msg for a completed token refresh attempt.
type refreshTokenResult struct {
	token        string
	refreshToken string
	expiresIn    int
	err          error
}

func (m Model) doRefreshToken(refreshToken string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.RefreshToken(refreshToken)
		if err != nil {
			return refreshTokenResult{err: err}
		}
		pd := profileDirPath()
		if pd != "" {
			_ = os.WriteFile(filepath.Join(pd, "token"), []byte(resp.Token), 0600)
			if resp.RefreshToken != "" {
				_ = os.WriteFile(filepath.Join(pd, "refresh_token"), []byte(resp.RefreshToken), 0600)
			}
		}
		return refreshTokenResult{token: resp.Token, refreshToken: resp.RefreshToken, expiresIn: resp.ExpiresIn}
	}
}

func (m Model) handleRefreshTokenResult(r refreshTokenResult) (Model, tea.Cmd) {
	if r.err != nil {
		// Refresh failed — fall back to manual re-login
		m.chat.AddSystemWarning("Session expired. Use /login to re-authenticate.")
		m.state = StateIdle
		return m, m.input.Focus()
	}
	// Refresh succeeded: update client token and store new refresh token
	m.client.SetToken(r.token)
	m.refreshToken = r.refreshToken
	// Restart SSE with new token
	if m.program != nil && m.sessionID != "" {
		return m, m.startSSE()
	}
	return m, nil
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
	m.sseReconnecting = false
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
		return commandsLoaded(commands)
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
		// Activity is rendered inline in the chat viewport, no separate reservation.
		// Only reserve for agents panel (rendered separately below chat).
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

// dynamicHelpText builds help output from backend command entries, grouped by category.
// Falls back to static help if no commands were fetched.
func (m Model) dynamicHelpText() string {
	if len(m.commandEntries) == 0 {
		return staticHelpText()
	}

	// Group commands by category
	categoryOrder := []string{
		"info", "session", "channels", "context", "intelligence",
		"config", "agents", "workflow", "priming", "security",
		"memory", "scheduler", "tasks", "analytics", "auth", "system",
	}
	categoryLabels := map[string]string{
		"info": "Info", "session": "Session", "channels": "Channels",
		"context": "Context", "intelligence": "Intelligence",
		"config": "Configuration", "agents": "Agents & Swarms",
		"workflow": "Workflow", "priming": "Context Priming",
		"security": "Security", "memory": "Memory",
		"scheduler": "Scheduler", "tasks": "Tasks",
		"analytics": "Analytics & Tools", "auth": "Authentication",
		"system": "System",
	}

	groups := make(map[string][]client.CommandEntry)
	for _, cmd := range m.commandEntries {
		cat := cmd.Category
		if cat == "" {
			cat = "system"
		}
		groups[cat] = append(groups[cat], cmd)
	}

	var b strings.Builder
	b.WriteString("Available commands:\n")

	for _, cat := range categoryOrder {
		cmds, ok := groups[cat]
		if !ok || len(cmds) == 0 {
			continue
		}
		label := categoryLabels[cat]
		if label == "" {
			label = cat
		}
		b.WriteString(fmt.Sprintf("\n  %s:\n", label))
		for _, cmd := range cmds {
			b.WriteString(fmt.Sprintf("    /%-18s %s\n", cmd.Name, cmd.Description))
		}
	}

	// Add any categories not in the order list
	for cat, cmds := range groups {
		found := false
		for _, c := range categoryOrder {
			if c == cat {
				found = true
				break
			}
		}
		if !found && len(cmds) > 0 {
			b.WriteString(fmt.Sprintf("\n  %s:\n", cat))
			for _, cmd := range cmds {
				b.WriteString(fmt.Sprintf("    /%-18s %s\n", cmd.Name, cmd.Description))
			}
		}
	}

	b.WriteString(keybindingsHelp())

	return b.String()
}

func staticHelpText() string {
	return `Commands:
  /help          Show this help
  /status        System status
  /models        Browse & switch models (↑↓ picker)
  /model         Show current model
  /model <name>  Switch to model (e.g. /model qwen3:8b)
  /agents        List agent roster
  /tools         List available tools
  /sessions      List all sessions
  /session       Show current session
  /session new   Create new session
  /session <id>  Switch to session
  /bg            List background tasks
  /theme         List or switch themes
  /clear         Clear chat history
  /exit          Exit OSA
` + keybindingsHelp()
}

func keybindingsHelp() string {
	return `
Keybindings:
  Enter        Submit message
  Alt+Enter    Insert newline (multi-line input)
  Ctrl+C       Cancel / quit
  Ctrl+O       Expand/collapse details
  Ctrl+B       Move task to background
  Ctrl+K       Command palette
  Ctrl+N       New session
  Ctrl+U       Clear input
  F1           Show this help
  Home         Scroll to top
  End          Scroll to bottom
  PgUp/PgDn    Scroll chat history
  Tab          Autocomplete commands
  Up/Down      Navigate input history

Tips:
  · Use Alt+Enter to compose multi-line messages
  · Ctrl+B moves a running task to background
  · /sessions lists sessions; /session <id> to switch`
}

// -- Model management --

func (m Model) handleModelList(r msg.ModelListResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Failed to list models: %v", r.Err))
		return m, m.input.Focus()
	}
	if len(r.Models) == 0 {
		m.chat.AddSystemWarning(fmt.Sprintf("No models available. Current: %s. Is Ollama running?", m.banner.ModelName()))
		return m, m.input.Focus()
	}
	// Convert to picker items, optionally filtered by provider
	filter := m.pendingProviderFilter
	m.pendingProviderFilter = ""
	var items []model.PickerItem
	for _, entry := range r.Models {
		if filter != "" && strings.ToLower(entry.Provider) != filter {
			continue
		}
		items = append(items, model.PickerItem{
			Name:     entry.Name,
			Provider: entry.Provider,
			Size:     entry.Size,
			Active:   entry.Active,
		})
	}
	if len(items) == 0 {
		m.chat.AddSystemError(fmt.Sprintf("No models available for provider: %s. Is the API key configured?", filter))
		return m, m.input.Focus()
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].Provider != items[j].Provider {
			return items[i].Provider < items[j].Provider
		}
		return items[i].Name < items[j].Name
	})
	m.picker.SetWidth(m.width - 4)
	m.picker.SetItems(items)
	m.state = StateModelPicker
	m.input.Blur()
	return m, nil
}

func (m Model) handleModelSwitch(r msg.ModelSwitchResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Switch failed: %v", r.Err))
		return m, nil
	}
	m.status.SetProviderInfo(r.Provider, r.Model)
	m.banner.SetModelOverride(r.Provider, r.Model)
	m.chat.AddSystemMessage(fmt.Sprintf("Switched to %s / %s", r.Provider, r.Model))
	// Re-check health to confirm
	return m, m.checkHealth()
}

func (m Model) handlePickerChoice(c model.PickerChoice) (Model, tea.Cmd) {
	m.picker.Clear()
	m.state = StateIdle
	m.chat.AddSystemMessage(fmt.Sprintf("Switching to %s / %s...", c.Provider, c.Name))
	return m, tea.Batch(m.input.Focus(), m.switchModel(c.Provider, c.Name))
}

func (m Model) fetchModels() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.ListModels()
		if err != nil {
			return msg.ModelListResult{Err: err}
		}
		var models []msg.ModelEntry
		for _, entry := range resp.Models {
			models = append(models, msg.ModelEntry{
				Name:     entry.Name,
				Provider: entry.Provider,
				Size:     entry.Size,
				Active:   entry.Active,
			})
		}
		return msg.ModelListResult{Models: models, Current: resp.Current, Provider: resp.Provider}
	}
}

func (m Model) switchModel(provider, modelName string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.SwitchModel(client.ModelSwitchRequest{Provider: provider, Model: modelName})
		if err != nil {
			return msg.ModelSwitchResult{Err: err}
		}
		return msg.ModelSwitchResult{Provider: resp.Provider, Model: resp.Model}
	}
}

// -- Session management --

func (m Model) listSessions() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		sessions, err := c.ListSessions()
		if err != nil {
			return msg.SessionListResult{Err: err}
		}
		var result []msg.SessionInfo
		for _, s := range sessions {
			result = append(result, msg.SessionInfo{
				ID:           s.ID,
				CreatedAt:    s.CreatedAt,
				Title:        s.Title,
				MessageCount: s.MessageCount,
			})
		}
		return msg.SessionListResult{Sessions: result}
	}
}

func (m Model) createSession() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.CreateSession()
		if err != nil {
			return msg.SessionSwitchResult{Err: err}
		}
		return msg.SessionSwitchResult{SessionID: resp.ID}
	}
}

func (m Model) switchSession(id string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		info, err := c.GetSession(id)
		if err != nil {
			return msg.SessionSwitchResult{Err: err}
		}
		// Prefer messages embedded in the session info response.
		// Fall back to the dedicated messages endpoint if the list is empty.
		messages := info.Messages
		if len(messages) == 0 {
			fetched, err := c.GetSessionMessages(id)
			if err == nil {
				messages = fetched
			}
			// On error we still switch sessions — just without history.
		}
		var result []msg.SessionMessage
		for _, m := range messages {
			result = append(result, msg.SessionMessage{
				Role:      m.Role,
				Content:   m.Content,
				Timestamp: m.Timestamp,
			})
		}
		return msg.SessionSwitchResult{SessionID: info.ID, Messages: result}
	}
}

func (m Model) handleSessionList(r msg.SessionListResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Session list error: %v", r.Err))
		return m, nil
	}
	if len(r.Sessions) == 0 {
		m.chat.AddSystemMessage("No sessions found.")
		return m, nil
	}
	var sb strings.Builder
	sb.WriteString("Sessions:\n")
	for i, s := range r.Sessions {
		title := s.Title
		if title == "" {
			title = "(untitled)"
		}
		sb.WriteString(fmt.Sprintf("  %d. %s — %s (%d messages)\n", i+1, shortID(s.ID), title, s.MessageCount))
	}
	m.chat.AddSystemMessage(strings.TrimRight(sb.String(), "\n"))
	return m, nil
}

func (m Model) handleSessionSwitch(r msg.SessionSwitchResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Session error: %v", r.Err))
		return m, nil
	}
	m.closeSSE()
	m.sessionID = r.SessionID
	m.chat = model.NewChat(m.width, m.chatHeight())
	m.chat.SetWelcomeData(m.banner.Version(), m.banner.WelcomeLine(), m.banner.Workspace())

	// Replay message history when available.
	if len(r.Messages) > 0 {
		for _, sm := range r.Messages {
			switch sm.Role {
			case "user":
				m.chat.AddUserMessage(sm.Content)
			case "assistant":
				m.chat.AddAgentMessage(sm.Content, nil, 0, "")
			default:
				m.chat.AddSystemMessage(sm.Content)
			}
		}
		m.chat.AddSystemMessage(fmt.Sprintf("--- Resumed session %s (%d messages) ---", shortID(r.SessionID), len(r.Messages)))
	} else {
		m.chat.AddSystemMessage(fmt.Sprintf("Switched to session %s", shortID(r.SessionID)))
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

// shortID truncates an ID to 8 characters for display.
func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
