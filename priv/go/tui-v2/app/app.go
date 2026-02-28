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

	"charm.land/bubbles/v2/key"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/config"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/activity"
	"github.com/miosa/osa-tui/ui/chat"
	"github.com/miosa/osa-tui/ui/clipboard"
	"github.com/miosa/osa-tui/ui/completions"
	"github.com/miosa/osa-tui/ui/dialog"
	"github.com/miosa/osa-tui/ui/header"
	"github.com/miosa/osa-tui/ui/input"
	"github.com/miosa/osa-tui/ui/logo"
	"github.com/miosa/osa-tui/ui/selection"
	"github.com/miosa/osa-tui/ui/sidebar"
	"github.com/miosa/osa-tui/ui/status"
	"github.com/miosa/osa-tui/ui/toast"
)

// ProfileDir is set by main to the user's profile directory path.
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

// -- Internal message types ---------------------------------------------------

// ProgramReady is sent to the model after the tea.Program is created so it
// can store a reference for dispatching SSE events.
type ProgramReady struct{ Program *tea.Program }

type bannerTimeout struct{}
type commandsLoaded []client.CommandEntry
type toolCountLoaded int
type retryHealth struct{}

// refreshTokenResult carries the outcome of an automatic token refresh.
type refreshTokenResult struct {
	token        string
	refreshToken string
	expiresIn    int
	err          error
}

// -- Model --------------------------------------------------------------------

// Model is the root Bubble Tea model. It owns every sub-model and all
// wiring between the backend client and the UI.
type Model struct {
	header   header.Model
	chat     chat.Model
	input    input.Model
	activity activity.Model
	tasks    activity.TasksModel
	status   status.Model
	agents   activity.AgentsModel
	picker   dialog.PickerModel
	toasts   toast.ToastsModel
	palette  dialog.PaletteModel
	plan     dialog.PlanModel
	sidebar  sidebar.Model

	// New dialog models (Wave 4)
	permissions dialog.PermissionsModel
	sessions    dialog.SessionsModel
	quit        dialog.QuitModel
	models      dialog.ModelsModel

	// Text selection + clipboard (Wave 6)
	selection selection.Model

	state      State
	layout     Layout
	layoutMode LayoutMode

	client  *client.Client
	sse     *client.SSEClient
	program *tea.Program

	sessionID      string
	width          int
	height         int
	keys           KeyMap
	bgTasks        []string
	commandEntries []client.CommandEntry
	confirmQuit    bool

	processingStart  time.Time
	streamBuf        strings.Builder
	thinkingBuf      strings.Builder // accumulates ThinkingDelta text for the chat ThinkingBox
	sseReconnecting  bool            // true while a ReconnectListenCmd goroutine is in-flight
	responseReceived bool            // true once SSE agent_response rendered for current req
	cancelled        bool            // true when user cancelled the current request

	pendingProviderFilter string // set by "/model <provider>" to filter picker
	config                config.Config
	refreshToken          string
}

// New constructs the root Model.  It applies the persisted theme and
// determines the initial layout mode from the saved config.
func New(c *client.Client) Model {
	workspace, _ := os.Getwd()
	hdr := header.NewHeader()
	hdr.SetWorkspace(workspace)

	cfg := config.Load(profileDirPath())
	if cfg.Theme != "" {
		style.SetTheme(cfg.Theme)
	}

	layoutMode := LayoutCompact
	if cfg.SidebarOpen {
		layoutMode = LayoutSidebar
	}

	return Model{
		header:      hdr,
		chat:        chat.New(80, 20),
		input:       input.New(),
		activity:    activity.New(),
		tasks:       activity.NewTasks(),
		status:      status.New(),
		plan:        dialog.NewPlan(),
		agents:      activity.NewAgents(),
		picker:      dialog.NewPicker(),
		toasts:      toast.NewToasts(),
		palette:     dialog.NewPalette(),
		sidebar:     sidebar.New(),
		permissions: dialog.NewPermissions(),
		sessions:    dialog.NewSessions(),
		quit:        dialog.NewQuit(),
		models:      dialog.NewModels(),
		selection:   selection.New(),
		state:       StateConnecting,
		layoutMode:  layoutMode,
		client:      c,
		keys:        DefaultKeyMap(),
		width:       80,
		height:      24,
		config:      cfg,
	}
}

// SetRefreshToken stores the refresh token for automatic re-authentication.
func (m *Model) SetRefreshToken(t string) { m.refreshToken = t }

// -- Init ---------------------------------------------------------------------

func (m Model) Init() tea.Cmd {
	return tea.Batch(m.checkHealth(), m.input.Focus(), func() tea.Msg { return tea.RequestWindowSize() })
}

// -- Update -------------------------------------------------------------------

func (m Model) Update(rawMsg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch v := rawMsg.(type) {

	case tea.WindowSizeMsg:
		m.width = v.Width
		m.height = v.Height
		m.layout = ComputeLayout(
			v.Width, v.Height, m.layoutMode,
			countLines(m.status.View()),
			countLines(m.tasks.View()),
			countLines(m.agents.View()),
		)
		m.chat.SetSize(m.layout.ChatWidth, m.layout.ChatHeight)
		m.sidebar.SetSize(m.layout.SidebarWidth, m.layout.SidebarHeight)
		m.plan.SetWidth(v.Width - 4)
		m.picker.SetWidth(v.Width - 4)
		m.input.SetWidth(v.Width)
		m.header.SetWidth(v.Width)
		m.permissions.SetSize(v.Width, v.Height)
		m.sessions.SetSize(v.Width, v.Height)
		m.quit.SetSize(v.Width, v.Height)
		m.models.SetSize(v.Width, v.Height)
		return m, nil

	case tea.MouseClickMsg:
		switch m.state {
		case StateIdle, StateProcessing, StatePlanReview:
			var cmd tea.Cmd
			m.chat, cmd = m.chat.Update(v)
			return m, cmd
		case StateModelPicker:
			var cmd tea.Cmd
			m.picker, cmd = m.picker.Update(v)
			return m, cmd
		}
		return m, nil

	case tea.MouseWheelMsg:
		switch m.state {
		case StateIdle, StateProcessing, StatePlanReview:
			var cmd tea.Cmd
			m.chat, cmd = m.chat.Update(v)
			return m, cmd
		}
		return m, nil

	case tea.KeyPressMsg:
		return m.handleKey(v)

	// -- Program lifecycle --

	case ProgramReady:
		m.program = v.Program
		if m.sessionID != "" && m.sse == nil {
			return m, m.startSSE()
		}
		return m, nil

	// -- Health / connection --

	case msg.HealthResult:
		return m.handleHealth(v)

	case retryHealth:
		return m, m.checkHealth()

	case bannerTimeout:
		if m.state == StateBanner {
			m.state = StateIdle
			m.recomputeLayout()
			return m, m.input.Focus()
		}
		return m, nil

	// -- Orchestration --

	case msg.OrchestrateResult:
		return m.handleOrchestrate(v)

	case msg.CommandResult:
		return m.handleCommand(v)

	case commandsLoaded:
		m.commandEntries = []client.CommandEntry(v)
		names := make([]string, len(v))
		items := make([]completions.CompletionItem, len(v))
		for i, cmd := range v {
			names[i] = "/" + cmd.Name
			items[i] = completions.CompletionItem{
				Name:        "/" + cmd.Name,
				Description: cmd.Description,
				Category:    cmd.Category,
				Icon:        "/",
			}
		}
		m.input.SetCommands(names)
		m.input.SetCompletions(items)
		return m, nil

	case toolCountLoaded:
		m.header.SetToolCount(int(v))
		m.chat.SetWelcomeData(m.header.Version(), m.header.WelcomeLine(), m.header.Workspace())
		return m, nil

	// -- SSE lifecycle --

	case client.SSEConnectedEvent:
		m.sessionID = v.SessionID
		m.sseReconnecting = false
		return m, nil

	case client.SSEDisconnectedEvent:
		if m.sseReconnecting {
			return m, nil
		}
		if m.sessionID != "" && m.sse != nil && !m.sse.IsClosed() && m.program != nil {
			m.sseReconnecting = true
			return m, m.sse.ReconnectListenCmd(m.program)
		}
		return m, nil

	case client.SSEReconnectingEvent:
		m.chat.AddSystemWarning(fmt.Sprintf(
			"Connection lost. Reconnecting (attempt %d/%d)...", v.Attempt, client.MaxReconnects,
		))
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

	// -- Auth --

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

	// -- Sessions --

	case msg.SessionListResult:
		return m.handleSessionList(v)

	case msg.SessionSwitchResult:
		return m.handleSessionSwitch(v)

	// -- Streaming / SSE agent events --

	case client.StreamingTokenEvent:
		m.streamBuf.WriteString(v.Text)
		m.chat.SetStreamingContent(m.streamBuf.String())
		return m, nil

	case client.ThinkingDeltaEvent:
		m.activity, _ = m.activity.Update(msg.ThinkingDelta{Text: v.Text})
		m.thinkingBuf.WriteString(v.Text)
		m.chat.SetThinkingContent(m.thinkingBuf.String())
		return m, nil

	case client.AgentResponseEvent:
		m.streamBuf.Reset()
		return m.handleClientAgentResponse(v)

	case client.LLMRequestEvent:
		m.activity, _ = m.activity.Update(msg.LLMRequest{Iteration: v.Iteration})
		return m, nil

	case client.ToolCallStartEvent:
		m.activity, _ = m.activity.Update(msg.ToolCallStart{Name: v.Name, Args: v.Args})
		m.chat.TrackToolStart(v.Name, v.Args)
		return m, nil

	case client.ToolCallEndEvent:
		m.activity, _ = m.activity.Update(msg.ToolCallEnd{Name: v.Name, DurationMs: v.DurationMs, Success: v.Success})
		m.chat.TrackToolEnd(v.Name, v.DurationMs, v.Success)
		return m, nil

	case client.LLMResponseEvent:
		m.activity, _ = m.activity.Update(msg.LLMResponse{
			DurationMs:   v.DurationMs,
			InputTokens:  v.InputTokens,
			OutputTokens: v.OutputTokens,
		})
		m.status.SetStats(time.Since(m.processingStart), m.activity.ToolCount(), v.InputTokens, v.OutputTokens)
		return m, nil

	case client.ContextPressureEvent:
		m.status.SetContext(v.Utilization, v.MaxTokens, v.EstimatedTokens)
		m.sidebar.SetContext(v.Utilization, v.MaxTokens, v.EstimatedTokens)
		return m, nil

	// -- Tasks --

	case client.TaskCreatedEvent:
		m.tasks.AddTask(activity.Task{
			ID:         v.TaskID,
			Subject:    v.Subject,
			Status:     "pending",
			ActiveForm: v.ActiveForm,
		})
		return m, nil

	case client.TaskUpdatedEvent:
		m.tasks.UpdateTask(v.TaskID, v.Status)
		return m, nil

	// -- Orchestrator multi-agent events --

	case client.OrchestratorTaskStartedEvent:
		m.agents.Start()
		return m, nil

	case client.OrchestratorWaveStartedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorWaveStarted{
			WaveNumber: v.WaveNumber,
			TotalWaves: v.TotalWaves,
		})
		return m, nil

	case client.OrchestratorAgentStartedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentStarted{
			AgentName: v.AgentName,
			Role:      v.Role,
			Model:     v.Model,
		})
		return m, nil

	case client.OrchestratorAgentProgressEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentProgress{
			AgentName:     v.AgentName,
			CurrentAction: v.CurrentAction,
			ToolUses:      v.ToolUses,
			TokensUsed:    v.TokensUsed,
		})
		return m, nil

	case client.OrchestratorAgentCompletedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentCompleted{
			AgentName:  v.AgentName,
			ToolUses:   v.ToolUses,
			TokensUsed: v.TokensUsed,
		})
		return m, nil

	case client.OrchestratorAgentFailedEvent:
		m.agents, _ = m.agents.Update(msg.OrchestratorAgentFailed{
			AgentName:  v.AgentName,
			Error:      v.Error,
			ToolUses:   v.ToolUses,
			TokensUsed: v.TokensUsed,
		})
		return m, nil

	case client.OrchestratorTaskCompletedEvent:
		m.agents.Stop()
		return m, nil

	// -- Swarm events --

	case client.SwarmStartedEvent:
		m.chat.AddSystemMessage(fmt.Sprintf(
			"Swarm launched: %s pattern with %d agents", v.Pattern, v.AgentCount,
		))
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
		m.chat.AddSystemMessage(fmt.Sprintf(
			"Swarm intelligence (%s) started: %s", v.Type, v.Task,
		))
		return m, nil

	case client.SwarmIntelligenceRoundEvent:
		m.chat.AddSystemMessage(fmt.Sprintf("Swarm intelligence round %d", v.Round))
		return m, nil

	case client.SwarmIntelligenceConvergedEvent:
		m.chat.AddSystemMessage(fmt.Sprintf("Swarm intelligence converged at round %d", v.Round))
		return m, nil

	case client.SwarmIntelligenceCompletedEvent:
		statusStr := "completed"
		if v.Converged {
			statusStr = "converged"
		}
		m.chat.AddSystemMessage(fmt.Sprintf(
			"Swarm intelligence %s after %d rounds", statusStr, v.Rounds,
		))
		return m, nil

	// -- Hook / budget events --

	case client.HookBlockedEvent:
		m.chat.AddSystemError(fmt.Sprintf("Blocked by %s: %s", v.HookName, v.Reason))
		return m, nil

	case client.BudgetWarningEvent:
		m.chat.AddSystemWarning(fmt.Sprintf("Budget at %.0f%%: %s", v.Utilization*100, v.Message))
		return m, nil

	case client.BudgetExceededEvent:
		m.chat.AddSystemError(fmt.Sprintf("Budget exceeded: %s", v.Message))
		return m, nil

	// -- Tool results --

	case client.ToolResultEvent:
		m.activity, _ = m.activity.Update(msg.ToolResult{Name: v.Name, Result: v.Result, Success: v.Success})
		m.chat.TrackToolResult(v.Name, v.Result, v.Success)
		return m, nil

	// -- Signal classification --

	case client.SignalClassifiedEvent:
		sig := &status.Signal{Mode: v.Mode, Genre: v.Genre, Type: v.Type, Weight: v.Weight}
		m.status.SetSignal(sig)
		return m, nil

	// -- Parse warnings (toasts) --

	case client.SSEParseWarning:
		m.toasts.Add(v.Message, toast.ToastWarning)
		return m, m.tickCmd()

	case msg.SSEParseWarning:
		m.toasts.Add(v.Message, toast.ToastWarning)
		return m, m.tickCmd()

	// -- UI toggle events --

	case msg.ToggleExpand:
		m.activity, _ = m.activity.Update(v)
		m.agents, _ = m.agents.Update(v)
		m.tasks = m.tasks.Update(v)
		return m, nil

	case msg.ToggleSidebar:
		if m.layoutMode == LayoutSidebar {
			m.layoutMode = LayoutCompact
			m.config.SidebarOpen = false
		} else {
			m.layoutMode = LayoutSidebar
			m.config.SidebarOpen = true
		}
		_ = config.Save(profileDirPath(), m.config)
		m.recomputeLayout()
		return m, nil

	// -- Tick --

	case msg.TickMsg:
		m.toasts.Tick()
		needTick := false
		if m.state == StateProcessing {
			m.status.SetStats(
				time.Since(m.processingStart),
				m.activity.ToolCount(),
				m.activity.InputTokens(),
				m.activity.OutputTokens(),
			)
			m.recomputeLayout()
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

	// -- Dialog messages --

	case dialog.PlanDecision:
		return m.handlePlanDecision(v)

	case msg.ModelListResult:
		return m.handleModelList(v)

	case msg.ModelSwitchResult:
		return m.handleModelSwitch(v)

	case dialog.PickerChoice:
		return m.handlePickerChoice(v)

	case dialog.PickerCancel:
		m.picker.Clear()
		m.state = StateIdle
		return m, m.input.Focus()

	case dialog.PaletteExecuteMsg:
		m.state = StateIdle
		return m.submitInput(v.Command)

	case dialog.PaletteDismissMsg:
		m.state = StateIdle
		return m, m.input.Focus()

	// -- New dialog messages (Wave 4) --

	case dialog.PermissionDecision:
		return m.handlePermissionDecision(v)

	case dialog.SessionAction:
		return m.handleSessionAction(v)

	case dialog.ModelChoice:
		return m.handleModelsChoice(v)

	case dialog.ModelCancel:
		m.state = StateIdle
		return m, m.input.Focus()

	case dialog.QuitConfirmed:
		m.closeSSE()
		return m, tea.Quit

	case dialog.QuitCancelled:
		m.state = StateIdle
		m.confirmQuit = false
		return m, m.input.Focus()
	}

	// Forward to activity during processing (handles spinner ticks, etc.)
	if m.state == StateProcessing {
		var cmd tea.Cmd
		m.activity, cmd = m.activity.Update(rawMsg)
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}

// -- View ---------------------------------------------------------------------

// View returns the tea.View for the current frame.
// AltScreen, MouseMode, and ReportFocus are set on every frame.
func (m Model) View() tea.View {
	content := m.renderView()
	v := tea.NewView(content)
	v.AltScreen = true
	v.MouseMode = tea.MouseModeCellMotion
	v.ReportFocus = true
	return v
}

// renderView composes the full terminal frame as a string.
func (m Model) renderView() string {
	// Full-screen overlay states — shortcut out.
	if m.state == StatePalette && m.palette.IsActive() {
		return m.palette.View()
	}
	if m.state == StatePermissions {
		return m.permissions.View()
	}
	if m.state == StateQuit {
		return m.quit.View()
	}
	if m.state == StateSessions {
		return m.sessions.View()
	}
	if m.state == StateModels {
		return m.models.View()
	}

	var sections []string

	switch m.state {
	case StateConnecting:
		sections = append(sections, m.renderConnecting())

	case StateBanner:
		sections = append(sections, m.header.ViewFull())
		sections = append(sections, "")
		sections = append(sections, m.input.View())

	default:
		// Header is common to all non-connecting, non-banner states.
		sections = append(sections, m.header.HeaderView())

		// Main content: optional sidebar | chat
		mainContent := m.renderMain()
		sections = append(sections, mainContent)

		// Task checklist
		if m.tasks.HasTasks() {
			sections = append(sections, m.tasks.View())
		}

		// Multi-agent panel (processing state only)
		if m.state == StateProcessing && m.agents.IsActive() {
			sections = append(sections, m.agents.View())
		}

		// Plan overlay (replaces input when reviewing)
		if m.state == StatePlanReview {
			sections = append(sections, m.plan.View())
		}

		// Model picker overlay
		if m.state == StateModelPicker {
			sections = append(sections, m.picker.View())
		}

		// Status bar
		sections = append(sections, m.status.View())

		// Input (hidden during plan review and model picker)
		if m.state != StatePlanReview && m.state != StateModelPicker {
			sections = append(sections, m.input.View())
		}
	}

	// Toasts overlay
	if m.toasts.HasToasts() {
		sections = append(sections, m.toasts.View(m.width))
	}

	// (confirmQuit replaced by QuitModel dialog)

	return strings.Join(sections, "\n")
}

// renderMain returns the main chat area, optionally side-by-side with the sidebar.
// The chat model's View() already renders the welcome screen when there are no messages.
func (m Model) renderMain() string {
	chatView := m.chat.View()

	if m.layout.Mode == LayoutSidebar && m.layout.SidebarWidth > 0 {
		return lipgloss.JoinHorizontal(lipgloss.Top, m.sidebar.View(), chatView)
	}
	return chatView
}

// -- Key handling -------------------------------------------------------------

func (m Model) handleKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
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
	case StateBanner:
		m.state = StateIdle
		return m, m.input.Focus()
	}
	return m, nil
}

func (m Model) handleIdleKey(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
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

// -- Input submission ---------------------------------------------------------

// submitInput routes typed text to the appropriate handler.
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
	m.responseReceived = false
	m.cancelled = false
	m.state = StateProcessing
	m.processingStart = time.Now()
	m.status.SetActive(true)
	m.chat.SetProcessingView(m.activity.View())
	m.input.Blur()
	return m, tea.Batch(m.orchestrate(text), m.tickCmd())
}

// -- Health -------------------------------------------------------------------

func (m Model) handleHealth(h msg.HealthResult) (Model, tea.Cmd) {
	if h.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Backend unreachable: %v -- retrying in 5s", h.Err))
		m.state = StateConnecting
		return m, tea.Tick(5*time.Second, func(time.Time) tea.Msg { return retryHealth{} })
	}

	m.header.SetHealth(h)
	m.status.SetProviderInfo(h.Provider, h.Model)
	m.sidebar.SetModelInfo(h.Provider, h.Model)
	m.state = StateBanner

	b := make([]byte, 4)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		b = []byte{0, 0, 0, 0}
	}
	m.sessionID = generateSessionID(b)

	m.chat.SetWelcomeData(m.header.Version(), m.header.WelcomeLine(), m.header.Workspace())
	m.recomputeLayout()

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

// -- Orchestration ------------------------------------------------------------

func (m Model) handleOrchestrate(r msg.OrchestrateResult) (Model, tea.Cmd) {
	// If user cancelled, silently drop the late-arriving response.
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

	// If SSE already rendered this response, skip duplicate.
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

	// Plan responses go to the plan review UI.
	if r.ResponseType == "plan" {
		m.activity.Stop()
		m.chat.ClearProcessingView()
		m.status.SetActive(false)
		m.plan.SetPlan(r.Output)
		m.state = StatePlanReview
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

	sig := msgSignalToChat(r.Signal)
	m.chat.AddAgentMessage(output, sig, r.ExecutionMs, m.header.ModelName())
	if sig != nil {
		m.status.SetSignal(&status.Signal{
			Mode:  sig.Mode,
			Genre: sig.Genre,
			Type:  sig.Type,
		})
	}

	if r.SessionID != "" && m.sessionID != r.SessionID {
		m.sessionID = r.SessionID
	}
	if m.sse == nil && m.program != nil && m.sessionID != "" {
		if cmd := m.startSSE(); cmd != nil {
			cmds = append(cmds, cmd)
		}
	}
	return m, tea.Batch(cmds...)
}

func (m Model) handleClientAgentResponse(r client.AgentResponseEvent) (Model, tea.Cmd) {
	// Drop if cancelled or REST already rendered.
	if m.cancelled || m.responseReceived {
		return m, nil
	}

	if r.ResponseType == "plan" {
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
	focusCmd := m.input.Focus()

	if wasBackground {
		m.chat.AddSystemMessage("Background task completed")
		if len(m.bgTasks) > 0 {
			m.bgTasks = m.bgTasks[1:]
		}
		m.status.SetBackgroundCount(len(m.bgTasks))
	}

	sig := clientSignalToChat(r.Signal)
	m.chat.AddAgentMessage(
		truncateResponse(r.Response), sig,
		time.Since(m.processingStart).Milliseconds(),
		m.header.ModelName(),
	)
	if sig != nil {
		m.status.SetSignal(&status.Signal{Mode: sig.Mode, Genre: sig.Genre, Type: sig.Type})
	}
	return m, focusCmd
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
		m.responseReceived = false
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

// -- Auth helpers -------------------------------------------------------------

func (m Model) doLogin(userID string) tea.Cmd {
	c := m.client
	return func() tea.Msg {
		resp, err := c.Login(userID)
		if err != nil {
			return msg.LoginResult{Err: err}
		}
		pd := profileDirPath()
		if pd != "" {
			if err := os.MkdirAll(pd, 0o755); err != nil {
				return msg.LoginResult{Err: fmt.Errorf("create profile dir: %w", err)}
			}
			if err := os.WriteFile(filepath.Join(pd, "token"), []byte(resp.Token), 0o600); err != nil {
				return msg.LoginResult{Token: resp.Token, Err: fmt.Errorf("save token: %w", err)}
			}
			if resp.RefreshToken != "" {
				_ = os.WriteFile(filepath.Join(pd, "refresh_token"), []byte(resp.RefreshToken), 0o600)
			}
		}
		return msg.LoginResult{Token: resp.Token, RefreshToken: resp.RefreshToken, ExpiresIn: resp.ExpiresIn}
	}
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
			_ = os.WriteFile(filepath.Join(pd, "token"), []byte(resp.Token), 0o600)
			if resp.RefreshToken != "" {
				_ = os.WriteFile(filepath.Join(pd, "refresh_token"), []byte(resp.RefreshToken), 0o600)
			}
		}
		return refreshTokenResult{
			token:        resp.Token,
			refreshToken: resp.RefreshToken,
			expiresIn:    resp.ExpiresIn,
		}
	}
}

func (m Model) handleRefreshTokenResult(r refreshTokenResult) (Model, tea.Cmd) {
	if r.err != nil {
		m.chat.AddSystemWarning("Session expired. Use /login to re-authenticate.")
		m.state = StateIdle
		return m, m.input.Focus()
	}
	m.client.SetToken(r.token)
	m.refreshToken = r.refreshToken
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

// -- SSE management ----------------------------------------------------------

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

// -- Health check ------------------------------------------------------------

func (m Model) checkHealth() tea.Cmd {
	c := m.client
	return func() tea.Msg {
		health, err := c.Health()
		if err != nil {
			return msg.HealthResult{Err: err}
		}
		return msg.HealthResult{
			Status:   health.Status,
			Version:  health.Version,
			Provider: health.Provider,
			Model:    health.Model,
		}
	}
}

// -- Orchestrate commands ----------------------------------------------------

func (m Model) orchestrate(inputText string) tea.Cmd {
	return m.orchestrateWithOpts(inputText, false)
}

func (m Model) orchestrateWithOpts(inputText string, skipPlan bool) tea.Cmd {
	c := m.client
	sid := m.sessionID
	return func() tea.Msg {
		resp, err := c.Orchestrate(client.OrchestrateRequest{
			Input:     inputText,
			SessionID: sid,
			SkipPlan:  skipPlan,
		})
		if err != nil {
			return msg.OrchestrateResult{Err: err}
		}
		r := msg.OrchestrateResult{
			SessionID:      resp.SessionID,
			ResponseType:   resp.ResponseType,
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

// -- Model selection ---------------------------------------------------------

func (m Model) handleModelList(r msg.ModelListResult) (Model, tea.Cmd) {
	if r.Err != nil {
		m.chat.AddSystemError(fmt.Sprintf("Failed to list models: %v", r.Err))
		return m, m.input.Focus()
	}
	if len(r.Models) == 0 {
		m.chat.AddSystemWarning(fmt.Sprintf(
			"No models available. Current: %s. Is Ollama running?", m.header.ModelName(),
		))
		return m, m.input.Focus()
	}

	filter := m.pendingProviderFilter
	m.pendingProviderFilter = ""

	var items []dialog.PickerItem
	for _, entry := range r.Models {
		if filter != "" && strings.ToLower(entry.Provider) != filter {
			continue
		}
		items = append(items, dialog.PickerItem{
			Name:     entry.Name,
			Provider: entry.Provider,
			Size:     entry.Size,
			Active:   entry.Active,
		})
	}

	if len(items) == 0 {
		m.chat.AddSystemError(fmt.Sprintf(
			"No models available for provider: %s. Is the API key configured?", filter,
		))
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
	m.header.SetModelOverride(r.Provider, r.Model)
	m.sidebar.SetModelInfo(r.Provider, r.Model)
	m.chat.AddSystemMessage(fmt.Sprintf("Switched to %s / %s", r.Provider, r.Model))
	return m, m.checkHealth()
}

func (m Model) handlePickerChoice(c dialog.PickerChoice) (Model, tea.Cmd) {
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

// -- Session management -------------------------------------------------------

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
		messages := info.Messages
		if len(messages) == 0 {
			fetched, err := c.GetSessionMessages(id)
			if err == nil {
				messages = fetched
			}
		}
		var result []msg.SessionMessage
		for _, sm := range messages {
			result = append(result, msg.SessionMessage{
				Role:      sm.Role,
				Content:   sm.Content,
				Timestamp: sm.Timestamp,
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
		sb.WriteString(fmt.Sprintf("  %d. %s — %s (%d messages)\n",
			i+1, shortID(s.ID), title, s.MessageCount,
		))
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
	m.chat = chat.New(m.layout.ChatWidth, m.layout.ChatHeight)
	m.chat.SetWelcomeData(m.header.Version(), m.header.WelcomeLine(), m.header.Workspace())

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
		m.chat.AddSystemMessage(fmt.Sprintf(
			"--- Resumed session %s (%d messages) ---", shortID(r.SessionID), len(r.Messages),
		))
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

// -- Layout helpers -----------------------------------------------------------

// recomputeLayout recalculates the Layout struct from current dimensions and
// sub-model view heights, then propagates updated dimensions into sub-models.
func (m *Model) recomputeLayout() {
	m.layout = ComputeLayout(
		m.width, m.height, m.layoutMode,
		countLines(m.status.View()),
		countLines(m.tasks.View()),
		countLines(m.agents.View()),
	)
	m.chat.SetSize(m.layout.ChatWidth, m.layout.ChatHeight)
	m.sidebar.SetSize(m.layout.SidebarWidth, m.layout.SidebarHeight)
}

// countLines returns the number of lines in a rendered string.
func countLines(s string) int {
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}

// -- Rendering helpers --------------------------------------------------------

// renderConnecting shows the ASCII logo with a connecting message.
func (m Model) renderConnecting() string {
	gradLogo := logo.RenderWithGradient(m.width)
	label := style.BannerTitle.Render("  Connecting to OSA backend...")
	return gradLogo + "\n\n" + label
}

// osaLogo is the ASCII art displayed on startup and the connecting screen.
const osaLogo = ` ██████╗ ███████╗ █████╗
██╔═══██╗██╔════╝██╔══██╗
██║   ██║███████╗███████║
██║   ██║╚════██║██╔══██║
╚██████╔╝███████║██║  ██║
 ╚═════╝ ╚══════╝╚═╝  ╚═╝`

// -- Help text ----------------------------------------------------------------

// dynamicHelpText builds grouped help from fetched command entries.
// Falls back to staticHelpText when no commands have been fetched.
func (m Model) dynamicHelpText() string {
	if len(m.commandEntries) == 0 {
		return staticHelpText()
	}

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

	// Any categories not in the order list.
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
  Ctrl+L       Toggle sidebar
  Ctrl+O       Expand/collapse details
  Ctrl+T       Toggle thinking box
  Ctrl+B       Move task to background
  Ctrl+K       Command palette
  Ctrl+N       New session
  Ctrl+U       Clear input
  F1           Show this help
  Home         Scroll to top
  End          Scroll to bottom
  PgUp/PgDn    Scroll chat history
  j/k          Scroll (when input not focused)
  u/d          Half-page scroll (when input not focused)
  Tab          Autocomplete commands
  Up/Down      Navigate input history

Tips:
  · Use Alt+Enter to compose multi-line messages
  · Ctrl+B moves a running task to background
  · Ctrl+L toggles the sidebar panel
  · /sessions lists sessions; /session <id> to switch`
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

// -- New dialog decision handlers (Wave 4) ------------------------------------

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

func (m Model) handleSessionAction(a dialog.SessionAction) (Model, tea.Cmd) {
	m.state = StateIdle
	switch a.Action {
	case "switch":
		return m, tea.Batch(m.input.Focus(), m.switchSession(a.SessionID))
	case "create":
		return m, tea.Batch(m.input.Focus(), m.createSession())
	case "rename":
		m.chat.AddSystemMessage(fmt.Sprintf("Renamed session %s → %s", shortID(a.SessionID), a.NewName))
		return m, m.input.Focus()
	case "delete":
		m.chat.AddSystemMessage(fmt.Sprintf("Deleted session %s", shortID(a.SessionID)))
		return m, m.input.Focus()
	}
	return m, m.input.Focus()
}

func (m Model) handleModelsChoice(c dialog.ModelChoice) (Model, tea.Cmd) {
	m.state = StateIdle
	m.chat.AddSystemMessage(fmt.Sprintf("Switching to %s / %s...", c.Provider, c.Model))
	return m, tea.Batch(m.input.Focus(), m.switchModel(c.Provider, c.Model))
}

// -- Signal conversion helpers ------------------------------------------------

// msgSignalToChat converts a msg.Signal (from REST) to a *chat.Signal.
func msgSignalToChat(s *msg.Signal) *chat.Signal {
	if s == nil {
		return nil
	}
	return &chat.Signal{
		Mode:    s.Mode,
		Genre:   s.Genre,
		Type:    s.Type,
		Format:  s.Format,
		Weight:  s.Weight,
		Channel: s.Channel,
	}
}

// clientSignalToChat converts a *client.Signal (from SSE) to a *chat.Signal.
func clientSignalToChat(s *client.Signal) *chat.Signal {
	if s == nil {
		return nil
	}
	return &chat.Signal{
		Mode:    s.Mode,
		Genre:   s.Genre,
		Type:    s.Type,
		Format:  s.Format,
		Weight:  s.Weight,
		Channel: s.Channel,
	}
}

// -- Misc helpers -------------------------------------------------------------

// shortID truncates an ID to 8 characters for display.
func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// generateSessionID creates a time-based session ID with random suffix.
func generateSessionID(randBytes []byte) string {
	return fmt.Sprintf("tui_%d_%x", time.Now().UnixNano(), randBytes)
}
