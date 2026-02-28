package style

import "github.com/charmbracelet/lipgloss"

// Colors — matches OSA branding.
var (
	Primary   = lipgloss.Color("#7C3AED") // violet-600
	Secondary = lipgloss.Color("#06B6D4") // cyan-500
	Success   = lipgloss.Color("#22C55E") // green-500
	Warning   = lipgloss.Color("#F59E0B") // amber-500
	Error     = lipgloss.Color("#EF4444") // red-500
	Muted     = lipgloss.Color("#6B7280") // gray-500
	Dim       = lipgloss.Color("#374151") // gray-700
	Fg        = lipgloss.Color("#E5E7EB") // gray-200
	Bg        = lipgloss.Color("#111827") // gray-900
	Border    = lipgloss.Color("#4B5563") // gray-600

	// Message left-border colors (OpenCode style)
	MsgBorderUser    = lipgloss.Color("#06B6D4") // cyan — user messages
	MsgBorderAgent   = lipgloss.Color("#7C3AED") // violet — agent messages
	MsgBorderSystem  = lipgloss.Color("#374151") // dim — system messages
	MsgBorderWarning = lipgloss.Color("#F59E0B") // amber — warning messages
	MsgBorderError   = lipgloss.Color("#EF4444") // red — error messages
)

// Base styles.
var (
	Bold      = lipgloss.NewStyle().Bold(true)
	Faint     = lipgloss.NewStyle().Foreground(Muted)
	ErrorText = lipgloss.NewStyle().Foreground(Error).Bold(true)

	// Banner
	BannerTitle = lipgloss.NewStyle().
			Foreground(Primary).
			Bold(true)
	BannerDetail = lipgloss.NewStyle().
			Foreground(Muted)

	// Prompt
	PromptChar = lipgloss.NewStyle().
			Foreground(Primary).
			Bold(true)

	// Chat
	UserLabel = lipgloss.NewStyle().
			Foreground(Secondary).
			Bold(true)
	AgentLabel = lipgloss.NewStyle().
			Foreground(Primary).
			Bold(true)

	// Activity
	SpinnerStyle = lipgloss.NewStyle().
			Foreground(Primary)
	ToolName = lipgloss.NewStyle().
			Foreground(Secondary)
	ToolDuration = lipgloss.NewStyle().
			Foreground(Muted)
	ToolArg = lipgloss.NewStyle().
		Foreground(Dim)

	// Tasks
	TaskDone    = lipgloss.NewStyle().Foreground(Success)
	TaskActive  = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	TaskPending = lipgloss.NewStyle().Foreground(Muted)
	TaskFailed  = lipgloss.NewStyle().Foreground(Error)

	// Status bar
	StatusBar = lipgloss.NewStyle().
			Foreground(Muted).
			PaddingLeft(1)
	StatusSignal = lipgloss.NewStyle().
			Foreground(Secondary)
	ContextBar = lipgloss.NewStyle().
			Foreground(Primary)

	// Plan review
	PlanBorder = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(Border).
			Padding(1, 2)
	PlanSelected = lipgloss.NewStyle().
			Foreground(Primary).
			Bold(true)
	PlanUnselected = lipgloss.NewStyle().
			Foreground(Muted)

	// Agent display
	AgentName = lipgloss.NewStyle().
			Foreground(Secondary).
			Bold(true)
	AgentRole = lipgloss.NewStyle().
			Foreground(Muted)
	WaveLabel = lipgloss.NewStyle().
			Foreground(Primary).
			Bold(true)

	// Prefix characters (⏺ ✳)
	PrefixActive = lipgloss.NewStyle().
			Foreground(Primary).
			Bold(true)
	PrefixDone = lipgloss.NewStyle().
			Foreground(Success).
			Bold(true)
	PrefixThinking = lipgloss.NewStyle().
			Foreground(Warning).
			Bold(true)

	// Connector (⎿)
	Connector = lipgloss.NewStyle().
			Foreground(Muted)

	// Hint text (ctrl+b, ctrl+o)
	Hint = lipgloss.NewStyle().
		Foreground(Dim)

	// Message metadata (duration, model)
	MsgMeta = lipgloss.NewStyle().
		Foreground(Muted).
		Italic(true)

	// Welcome screen
	WelcomeTitle = lipgloss.NewStyle().
			Foreground(Primary).
			Bold(true)
	WelcomeMeta = lipgloss.NewStyle().
			Foreground(Muted)
	WelcomeCwd = lipgloss.NewStyle().
			Foreground(Secondary)
	WelcomeTip = lipgloss.NewStyle().
			Foreground(Dim)
)

// ContextBarRender renders a context utilization bar like: ██████░░░░ 62%
func ContextBarRender(utilization float64, width int) string {
	filled := int(utilization * float64(width))
	if filled > width {
		filled = width
	}
	empty := width - filled

	var color lipgloss.Color
	switch {
	case utilization >= 0.90:
		color = Error
	case utilization >= 0.75:
		color = Warning
	default:
		color = Primary
	}

	bar := lipgloss.NewStyle().Foreground(color).Render(repeat("█", filled)) +
		lipgloss.NewStyle().Foreground(Dim).Render(repeat("░", empty))

	return bar
}

func repeat(s string, n int) string {
	out := ""
	for i := 0; i < n; i++ {
		out += s
	}
	return out
}
