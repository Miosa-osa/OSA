package style

import (
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
)

// Colors — initialized to dark theme defaults. Updated via SetTheme().
var (
	Primary   color.Color = lipgloss.Color("#7C3AED")
	Secondary color.Color = lipgloss.Color("#06B6D4")
	Success   color.Color = lipgloss.Color("#22C55E")
	Warning   color.Color = lipgloss.Color("#F59E0B")
	Error     color.Color = lipgloss.Color("#EF4444")
	Muted     color.Color = lipgloss.Color("#6B7280")
	Dim       color.Color = lipgloss.Color("#374151")
	Border    color.Color = lipgloss.Color("#4B5563")

	MsgBorderUser    color.Color = lipgloss.Color("#06B6D4")
	MsgBorderAgent   color.Color = lipgloss.Color("#7C3AED")
	MsgBorderSystem  color.Color = lipgloss.Color("#374151")
	MsgBorderWarning color.Color = lipgloss.Color("#F59E0B")
	MsgBorderError   color.Color = lipgloss.Color("#EF4444")

	SidebarBg color.Color = lipgloss.Color("#1F2937")

	// Extended palette
	ModalBgColor   color.Color = lipgloss.Color("#111827")
	TooltipBgColor color.Color = lipgloss.Color("#1F2937")
	InputBgColor   color.Color = lipgloss.Color("#111827")

	// Selection / dialog / button
	SelectionBgColor      color.Color = lipgloss.Color("#312E81")
	DialogBgColor         color.Color = lipgloss.Color("#1F2937")
	ButtonActiveBgColor   color.Color = lipgloss.Color("#7C3AED")
	ButtonActiveTextColor color.Color = lipgloss.Color("#FFFFFF")

	// Gradient endpoints — default to dark theme violet→cyan
	GradColorA color.Color = lipgloss.Color("#7C3AED")
	GradColorB color.Color = lipgloss.Color("#06B6D4")
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

	// Tool renderers
	ToolHeader    lipgloss.Style
	ToolOutput    lipgloss.Style
	DiffAdd       lipgloss.Style
	DiffRemove    lipgloss.Style
	DiffContext   lipgloss.Style
	DiffHunkLabel lipgloss.Style
	CodeBlock     lipgloss.Style
	FilePath      lipgloss.Style

	// Sidebar
	SidebarStyle     lipgloss.Style
	SidebarTitle     lipgloss.Style
	SidebarLabel     lipgloss.Style
	SidebarValue     lipgloss.Style
	SidebarFileItem  lipgloss.Style
	SidebarSeparator lipgloss.Style

	// Thinking box
	ThinkingHeader  lipgloss.Style
	ThinkingContent lipgloss.Style

	// -------------------------------------------------------------------------
	// Modal / Overlay
	// -------------------------------------------------------------------------

	ModalBackdrop lipgloss.Style // dimmed background behind a modal
	ModalBorder   lipgloss.Style // modal frame border
	ModalTitle    lipgloss.Style // modal title text

	OverlayDim lipgloss.Style // content dimming when an overlay is active

	// -------------------------------------------------------------------------
	// Completions popup
	// -------------------------------------------------------------------------

	CompletionNormal   lipgloss.Style
	CompletionSelected lipgloss.Style
	CompletionMatch    lipgloss.Style // highlighted match characters
	CompletionCategory lipgloss.Style // category label

	// -------------------------------------------------------------------------
	// Tool boxes & status indicators
	// -------------------------------------------------------------------------

	ToolBox           lipgloss.Style // left-bordered output box
	ToolStatusPending lipgloss.Style
	ToolStatusRunning lipgloss.Style
	ToolStatusSuccess lipgloss.Style
	ToolStatusError   lipgloss.Style
	ToolStatusCancel  lipgloss.Style

	// Code display (file read / syntax)
	LineNumber  lipgloss.Style // line numbers in file output
	CodeKeyword lipgloss.Style // syntax keyword highlight
	CodeString  lipgloss.Style // syntax string highlight
	CodeComment lipgloss.Style // syntax comment highlight

	// -------------------------------------------------------------------------
	// Header / Logo
	// -------------------------------------------------------------------------

	HeaderSeparator lipgloss.Style // thin line below header
	HeaderVersion   lipgloss.Style
	HeaderProvider  lipgloss.Style
	HeaderModel     lipgloss.Style

	// -------------------------------------------------------------------------
	// Progress bar
	// -------------------------------------------------------------------------

	ProgressFilled lipgloss.Style
	ProgressEmpty  lipgloss.Style
	ProgressLabel  lipgloss.Style

	// -------------------------------------------------------------------------
	// Input area
	// -------------------------------------------------------------------------

	InputBorder      lipgloss.Style
	InputPlaceholder lipgloss.Style
	InputCursor      lipgloss.Style

	// -------------------------------------------------------------------------
	// Attachments
	// -------------------------------------------------------------------------

	AttachmentChip      lipgloss.Style
	AttachmentChipImage lipgloss.Style
	AttachmentDelete    lipgloss.Style

	// -------------------------------------------------------------------------
	// Tooltip / Help
	// -------------------------------------------------------------------------

	TooltipBg   lipgloss.Style
	TooltipText lipgloss.Style
	TooltipKey  lipgloss.Style // keyboard shortcut label

	HelpKey       lipgloss.Style // key binding display
	HelpDesc      lipgloss.Style // key description
	HelpSeparator lipgloss.Style

	// -------------------------------------------------------------------------
	// Dialog
	// -------------------------------------------------------------------------

	DialogBorder  lipgloss.Style
	DialogTitle   lipgloss.Style
	DialogHelp    lipgloss.Style
	DialogHelpKey lipgloss.Style

	// -------------------------------------------------------------------------
	// Buttons
	// -------------------------------------------------------------------------

	ButtonActive   lipgloss.Style
	ButtonInactive lipgloss.Style
	ButtonDanger   lipgloss.Style

	// -------------------------------------------------------------------------
	// Scrollbar
	// -------------------------------------------------------------------------

	ScrollbarThumb lipgloss.Style
	ScrollbarTrack lipgloss.Style

	// -------------------------------------------------------------------------
	// Text selection
	// -------------------------------------------------------------------------

	TextSelection lipgloss.Style

	// -------------------------------------------------------------------------
	// Radio buttons
	// -------------------------------------------------------------------------

	RadioOn  lipgloss.Style
	RadioOff lipgloss.Style

	// -------------------------------------------------------------------------
	// Section chrome
	// -------------------------------------------------------------------------

	SectionTitle  lipgloss.Style
	SectionBorder lipgloss.Style

	// -------------------------------------------------------------------------
	// LSP / MCP status
	// -------------------------------------------------------------------------

	LSPReady     lipgloss.Style
	LSPError     lipgloss.Style
	LSPStarting  lipgloss.Style
	MCPConnected lipgloss.Style
	MCPError     lipgloss.Style

	// -------------------------------------------------------------------------
	// File diff stats
	// -------------------------------------------------------------------------

	DiffAdditions lipgloss.Style // green +N
	DiffDeletions lipgloss.Style // red -N
)

func init() {
	rebuildStyles()
}

// SetTheme applies a named theme, updating all color vars and rebuilding styles.
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
	SidebarBg = t.SidebarBg
	ModalBgColor = t.ModalBg
	TooltipBgColor = t.TooltipBg
	InputBgColor = t.InputBg
	SelectionBgColor = t.SelectionBg
	DialogBgColor = t.DialogBg
	ButtonActiveBgColor = t.ButtonActiveBg
	ButtonActiveTextColor = t.ButtonActiveText
	GradColorA = t.GradA
	GradColorB = t.GradB
	rebuildStyles()
	return true
}

// IsDark returns whether the current theme is dark.
func IsDark() bool {
	return CurrentThemeName != "light"
}

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

	// Tool renderers
	ToolHeader = lipgloss.NewStyle().Foreground(Secondary).Bold(true)
	ToolOutput = lipgloss.NewStyle().Foreground(Muted)
	DiffAdd = lipgloss.NewStyle().Foreground(Success)
	DiffRemove = lipgloss.NewStyle().Foreground(Error)
	DiffContext = lipgloss.NewStyle().Foreground(Muted)
	DiffHunkLabel = lipgloss.NewStyle().Foreground(Secondary).Italic(true)
	CodeBlock = lipgloss.NewStyle().Foreground(Muted)
	FilePath = lipgloss.NewStyle().Foreground(Secondary).Underline(true)

	// Sidebar
	SidebarStyle = lipgloss.NewStyle().
		Border(lipgloss.NormalBorder(), false, true, false, false).
		BorderForeground(Border).
		PaddingLeft(1).PaddingRight(1)
	SidebarTitle = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	SidebarLabel = lipgloss.NewStyle().Foreground(Muted)
	SidebarValue = lipgloss.NewStyle().Foreground(Secondary)
	SidebarFileItem = lipgloss.NewStyle().Foreground(Muted)
	SidebarSeparator = lipgloss.NewStyle().Foreground(Dim)

	// Thinking
	ThinkingHeader = lipgloss.NewStyle().Foreground(Warning).Bold(true)
	ThinkingContent = lipgloss.NewStyle().Foreground(Dim)

	// -------------------------------------------------------------------------
	// Modal / Overlay
	// -------------------------------------------------------------------------

	ModalBackdrop = lipgloss.NewStyle().
		Background(ModalBgColor).
		Foreground(Muted)
	ModalBorder = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(Primary).
		Background(ModalBgColor)
	ModalTitle = lipgloss.NewStyle().
		Foreground(Primary).
		Bold(true)

	OverlayDim = lipgloss.NewStyle().Foreground(Dim)

	// -------------------------------------------------------------------------
	// Completions popup
	// -------------------------------------------------------------------------

	CompletionNormal = lipgloss.NewStyle().Foreground(Muted)
	CompletionSelected = lipgloss.NewStyle().
		Foreground(Primary).
		Bold(true).
		Background(Dim)
	CompletionMatch = lipgloss.NewStyle().Foreground(Secondary).Bold(true)
	CompletionCategory = lipgloss.NewStyle().Foreground(Warning).Bold(true)

	// -------------------------------------------------------------------------
	// Tool boxes & status indicators
	// -------------------------------------------------------------------------

	ToolBox = lipgloss.NewStyle().
		Border(lipgloss.ThickBorder(), false, false, false, true).
		BorderForeground(Border).
		PaddingLeft(1)

	ToolStatusPending = lipgloss.NewStyle().Foreground(Muted)
	ToolStatusRunning = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	ToolStatusSuccess = lipgloss.NewStyle().Foreground(Success).Bold(true)
	ToolStatusError = lipgloss.NewStyle().Foreground(Error).Bold(true)
	ToolStatusCancel = lipgloss.NewStyle().Foreground(Warning)

	// Code display
	LineNumber = lipgloss.NewStyle().Foreground(Dim)
	CodeKeyword = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	CodeString = lipgloss.NewStyle().Foreground(Success)
	CodeComment = lipgloss.NewStyle().Foreground(Muted).Italic(true)

	// -------------------------------------------------------------------------
	// Header / Logo
	// -------------------------------------------------------------------------

	HeaderSeparator = lipgloss.NewStyle().Foreground(Dim)
	HeaderVersion = lipgloss.NewStyle().Foreground(Muted)
	HeaderProvider = lipgloss.NewStyle().Foreground(Secondary)
	HeaderModel = lipgloss.NewStyle().Foreground(Primary)

	// -------------------------------------------------------------------------
	// Progress bar
	// -------------------------------------------------------------------------

	ProgressFilled = lipgloss.NewStyle().Foreground(Primary)
	ProgressEmpty = lipgloss.NewStyle().Foreground(Dim)
	ProgressLabel = lipgloss.NewStyle().Foreground(Muted)

	// -------------------------------------------------------------------------
	// Input area
	// -------------------------------------------------------------------------

	InputBorder = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(Border)
	InputPlaceholder = lipgloss.NewStyle().Foreground(Dim)
	InputCursor = lipgloss.NewStyle().Foreground(Primary)

	// -------------------------------------------------------------------------
	// Attachments
	// -------------------------------------------------------------------------

	AttachmentChip = lipgloss.NewStyle().
		Foreground(Secondary).
		Background(Dim).
		Padding(0, 1)
	AttachmentChipImage = lipgloss.NewStyle().
		Foreground(Warning).
		Background(Dim).
		Padding(0, 1)
	AttachmentDelete = lipgloss.NewStyle().Foreground(Error)

	// -------------------------------------------------------------------------
	// Tooltip / Help
	// -------------------------------------------------------------------------

	TooltipBg = lipgloss.NewStyle().
		Background(TooltipBgColor).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(Border).
		Padding(0, 1)
	TooltipText = lipgloss.NewStyle().Foreground(Muted)
	TooltipKey = lipgloss.NewStyle().Foreground(Secondary).Bold(true)

	HelpKey = lipgloss.NewStyle().Foreground(Secondary).Bold(true)
	HelpDesc = lipgloss.NewStyle().Foreground(Muted)
	HelpSeparator = lipgloss.NewStyle().Foreground(Dim)

	// -------------------------------------------------------------------------
	// Dialog
	// -------------------------------------------------------------------------

	DialogBorder = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(Primary).
		Background(DialogBgColor).
		Padding(1, 2)
	DialogTitle = lipgloss.NewStyle().
		Foreground(Primary).
		Bold(true)
	DialogHelp = lipgloss.NewStyle().Foreground(Muted)
	DialogHelpKey = lipgloss.NewStyle().Foreground(Secondary).Bold(true)

	// -------------------------------------------------------------------------
	// Buttons
	// -------------------------------------------------------------------------

	ButtonActive = lipgloss.NewStyle().
		Foreground(ButtonActiveTextColor).
		Background(ButtonActiveBgColor).
		Bold(true).
		Padding(0, 2)
	ButtonInactive = lipgloss.NewStyle().
		Foreground(Muted).
		Background(Dim).
		Padding(0, 2)
	ButtonDanger = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#FFFFFF")).
		Background(Error).
		Bold(true).
		Padding(0, 2)

	// -------------------------------------------------------------------------
	// Scrollbar
	// -------------------------------------------------------------------------

	ScrollbarThumb = lipgloss.NewStyle().Foreground(Primary)
	ScrollbarTrack = lipgloss.NewStyle().Foreground(Dim)

	// -------------------------------------------------------------------------
	// Text selection
	// -------------------------------------------------------------------------

	TextSelection = lipgloss.NewStyle().
		Background(SelectionBgColor).
		Foreground(lipgloss.Color("#FFFFFF"))

	// -------------------------------------------------------------------------
	// Radio buttons
	// -------------------------------------------------------------------------

	RadioOn = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	RadioOff = lipgloss.NewStyle().Foreground(Muted)

	// -------------------------------------------------------------------------
	// Section chrome
	// -------------------------------------------------------------------------

	SectionTitle = lipgloss.NewStyle().Foreground(Primary).Bold(true)
	SectionBorder = lipgloss.NewStyle().
		Border(lipgloss.NormalBorder()).
		BorderForeground(Border)

	// -------------------------------------------------------------------------
	// LSP / MCP status
	// -------------------------------------------------------------------------

	LSPReady = lipgloss.NewStyle().Foreground(Success).Bold(true)
	LSPError = lipgloss.NewStyle().Foreground(Error).Bold(true)
	LSPStarting = lipgloss.NewStyle().Foreground(Warning)
	MCPConnected = lipgloss.NewStyle().Foreground(Secondary).Bold(true)
	MCPError = lipgloss.NewStyle().Foreground(Error).Bold(true)

	// -------------------------------------------------------------------------
	// File diff stats
	// -------------------------------------------------------------------------

	DiffAdditions = lipgloss.NewStyle().Foreground(Success).Bold(true)
	DiffDeletions = lipgloss.NewStyle().Foreground(Error).Bold(true)
}

// ContextBarRender renders a context utilization bar like: ██████░░░░ 62%
func ContextBarRender(utilization float64, width int) string {
	filled := int(utilization * float64(width))
	if filled > width {
		filled = width
	}
	empty := width - filled

	var c color.Color
	switch {
	case utilization >= 0.90:
		c = Error
	case utilization >= 0.75:
		c = Warning
	default:
		c = Primary
	}

	bar := lipgloss.NewStyle().Foreground(c).Render(strings.Repeat("█", filled)) +
		lipgloss.NewStyle().Foreground(Dim).Render(strings.Repeat("░", empty))

	return bar
}
