package app

import (
	"os"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/miosa/osa-tui/client"
	"github.com/miosa/osa-tui/config"
	"github.com/miosa/osa-tui/style"
	"github.com/miosa/osa-tui/ui/activity"
	"github.com/miosa/osa-tui/ui/chat"
	"github.com/miosa/osa-tui/ui/dialog"
	"github.com/miosa/osa-tui/ui/header"
	"github.com/miosa/osa-tui/ui/input"
	"github.com/miosa/osa-tui/ui/selection"
	"github.com/miosa/osa-tui/ui/sidebar"
	"github.com/miosa/osa-tui/ui/status"
	"github.com/miosa/osa-tui/ui/toast"
)

// ProfileDir is set by main to the user's profile directory path.
var ProfileDir string

func profileDirPath() string { return ProfileDir }

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
	onboarding  dialog.OnboardingModel

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

	processingStart time.Time
	streamBuf       *strings.Builder
	thinkingBuf     *strings.Builder // accumulates ThinkingDelta text for the chat ThinkingBox
	sseReconnecting bool             // true while a ReconnectListenCmd goroutine is in-flight
	cancelled       bool             // true when user cancelled the current request

	pendingProviderFilter string // set by "/model <provider>" to filter picker
	forceOnboarding       bool   // true when /setup forces wizard regardless of config
	config                config.Config
	refreshToken          string

	// In-chat search (Ctrl+F)
	searchMode    bool
	searchQuery   string
	searchMatches []int
	searchCursor  int
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
		onboarding:  dialog.NewOnboarding(),
		selection:   selection.New(),
		state:       StateConnecting,
		layoutMode:  layoutMode,
		client:      c,
		keys:        DefaultKeyMap(),
		width:       80,
		height:      24,
		config:      cfg,
		streamBuf:   &strings.Builder{},
		thinkingBuf: &strings.Builder{},
	}
}

// SetRefreshToken stores the refresh token for automatic re-authentication.
func (m *Model) SetRefreshToken(t string)  { m.refreshToken = t }
func (m *Model) SetForceOnboarding(v bool) { m.forceOnboarding = v }

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
