package style

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Colors — initialized to dark theme defaults. Updated via SetTheme().
// Type is lipgloss.TerminalColor so themes can use any color representation.
var (
	Primary   lipgloss.TerminalColor = lipgloss.Color("#7C3AED") // violet-600
	Secondary lipgloss.TerminalColor = lipgloss.Color("#06B6D4") // cyan-500
	Success   lipgloss.TerminalColor = lipgloss.Color("#22C55E") // green-500
	Warning   lipgloss.TerminalColor = lipgloss.Color("#F59E0B") // amber-500
	Error     lipgloss.TerminalColor = lipgloss.Color("#EF4444") // red-500
	Muted     lipgloss.TerminalColor = lipgloss.Color("#6B7280") // gray-500
	Dim       lipgloss.TerminalColor = lipgloss.Color("#374151") // gray-700
	Border    lipgloss.TerminalColor = lipgloss.Color("#4B5563") // gray-600

	// Message left-border colors (OpenCode style)
	MsgBorderUser    lipgloss.TerminalColor = lipgloss.Color("#06B6D4") // cyan — user messages
	MsgBorderAgent   lipgloss.TerminalColor = lipgloss.Color("#7C3AED") // violet — agent messages
	MsgBorderSystem  lipgloss.TerminalColor = lipgloss.Color("#374151") // dim — system messages
	MsgBorderWarning lipgloss.TerminalColor = lipgloss.Color("#F59E0B") // amber — warning messages
	MsgBorderError   lipgloss.TerminalColor = lipgloss.Color("#EF4444") // red — error messages
)

// Base styles — rebuilt when the theme changes via rebuildStyles().
var (
	Bold      lipgloss.Style
	Faint     lipgloss.Style
	ErrorText lipgloss.Style

	// Banner
	BannerTitle  lipgloss.Style
	BannerDetail lipgloss.Style

	// Prompt
	PromptChar lipgloss.Style

	// Chat
	UserLabel  lipgloss.Style
	AgentLabel lipgloss.Style

	// Activity
	SpinnerStyle lipgloss.Style
	ToolName     lipgloss.Style
	ToolDuration lipgloss.Style
	ToolArg      lipgloss.Style

	// Tasks
	TaskDone    lipgloss.Style
	TaskActive  lipgloss.Style
	TaskPending lipgloss.Style
	TaskFailed  lipgloss.Style

	// Status bar
	StatusBar    lipgloss.Style
	StatusSignal lipgloss.Style
	ContextBar   lipgloss.Style

	// Plan review
	PlanBorder     lipgloss.Style
	PlanSelected   lipgloss.Style
	PlanUnselected lipgloss.Style

	// Agent display
	AgentName lipgloss.Style
	AgentRole lipgloss.Style
	WaveLabel lipgloss.Style

	// Prefix characters
	PrefixActive   lipgloss.Style
	PrefixDone     lipgloss.Style
	PrefixThinking lipgloss.Style

	// Connector
	Connector lipgloss.Style

	// Hint text
	Hint lipgloss.Style

	// Message metadata
	MsgMeta lipgloss.Style

	// Welcome screen
	WelcomeTitle lipgloss.Style
	WelcomeMeta  lipgloss.Style
	WelcomeCwd   lipgloss.Style
	WelcomeTip   lipgloss.Style
)

func init() {
	rebuildStyles()
}

// SetTheme applies a named theme, updating all color vars and rebuilding styles.
// Returns true if the theme was found, false otherwise.
func SetTheme(name string) bool {
	t, ok := Themes[name]
	if !ok {
		return false
	}
	CurrentThemeName = name
	Primary = t.Primary
	Secondary = t.Secondary
	Success = t.Success
	Warning = t.Warning
	Error = t.Error
	Muted = t.Muted
	Dim = t.Dim
	Border = t.Border
	MsgBorderUser = t.MsgBorderUser
	MsgBorderAgent = t.MsgBorderAgent
	MsgBorderSystem = t.MsgBorderSystem
	MsgBorderWarning = t.MsgBorderWarning
	MsgBorderError = t.MsgBorderError
	rebuildStyles()
	return true
}

// rebuildStyles re-constructs every package-level style var from the current
// color vars. Must be called after color vars change because lipgloss styles
// capture colors at construction time.
func rebuildStyles() {
	Bold = lipgloss.NewStyle().Bold(true)
	Faint = lipgloss.NewStyle().Foreground(Muted)
	ErrorText = lipgloss.NewStyle().Foreground(Error).Bold(true)

	BannerTitle = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	BannerDetail = lipgloss.NewStyle().Foreground(Muted)

	PromptChar = lipgloss.NewStyle().Foreground(Primary).Bold(true)

	UserLabel = lipgloss.NewStyle().Foreground(Secondary).Bold(true)
	AgentLabel = lipgloss.NewStyle().Foreground(Primary).Bold(true)

	SpinnerStyle = lipgloss.NewStyle().Foreground(Primary)
	ToolName = lipgloss.NewStyle().Foreground(Secondary)
	ToolDuration = lipgloss.NewStyle().Foreground(Muted)
	ToolArg = lipgloss.NewStyle().Foreground(Dim)

	TaskDone = lipgloss.NewStyle().Foreground(Success)
	TaskActive = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	TaskPending = lipgloss.NewStyle().Foreground(Muted)
	TaskFailed = lipgloss.NewStyle().Foreground(Error)

	StatusBar = lipgloss.NewStyle().Foreground(Muted).PaddingLeft(1)
	StatusSignal = lipgloss.NewStyle().Foreground(Secondary)
	ContextBar = lipgloss.NewStyle().Foreground(Primary)

	PlanBorder = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(Border).Padding(1, 2)
	PlanSelected = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	PlanUnselected = lipgloss.NewStyle().Foreground(Muted)

	AgentName = lipgloss.NewStyle().Foreground(Secondary).Bold(true)
	AgentRole = lipgloss.NewStyle().Foreground(Muted)
	WaveLabel = lipgloss.NewStyle().Foreground(Primary).Bold(true)

	PrefixActive = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	PrefixDone = lipgloss.NewStyle().Foreground(Success).Bold(true)
	PrefixThinking = lipgloss.NewStyle().Foreground(Warning).Bold(true)

	Connector = lipgloss.NewStyle().Foreground(Muted)
	Hint = lipgloss.NewStyle().Foreground(Dim)
	MsgMeta = lipgloss.NewStyle().Foreground(Muted).Italic(true)

	WelcomeTitle = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	WelcomeMeta = lipgloss.NewStyle().Foreground(Muted)
	WelcomeCwd = lipgloss.NewStyle().Foreground(Secondary)
	WelcomeTip = lipgloss.NewStyle().Foreground(Dim)
}

// ContextBarRender renders a context utilization bar like: ██████░░░░ 62%
func ContextBarRender(utilization float64, width int) string {
	filled := int(utilization * float64(width))
	if filled > width {
		filled = width
	}
	empty := width - filled

	var color lipgloss.TerminalColor
	switch {
	case utilization >= 0.90:
		color = Error
	case utilization >= 0.75:
		color = Warning
	default:
		color = Primary
	}

	bar := lipgloss.NewStyle().Foreground(color).Render(strings.Repeat("█", filled)) +
		lipgloss.NewStyle().Foreground(Dim).Render(strings.Repeat("░", empty))

	return bar
}
