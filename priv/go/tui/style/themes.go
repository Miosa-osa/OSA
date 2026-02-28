package style

import "github.com/charmbracelet/lipgloss"

// Theme defines a complete color palette for the TUI.
type Theme struct {
	Name                                              string
	Primary, Secondary, Success, Warning, Error       lipgloss.TerminalColor
	Muted, Dim, Border                                lipgloss.TerminalColor
	MsgBorderUser, MsgBorderAgent                     lipgloss.TerminalColor
	MsgBorderSystem, MsgBorderWarning, MsgBorderError lipgloss.TerminalColor
}

// Built-in themes.
var (
	darkTheme = Theme{
		Name:             "dark",
		Primary:          lipgloss.Color("#7C3AED"), // violet-600
		Secondary:        lipgloss.Color("#06B6D4"), // cyan-500
		Success:          lipgloss.Color("#22C55E"), // green-500
		Warning:          lipgloss.Color("#F59E0B"), // amber-500
		Error:            lipgloss.Color("#EF4444"), // red-500
		Muted:            lipgloss.Color("#6B7280"), // gray-500
		Dim:              lipgloss.Color("#374151"), // gray-700
		Border:           lipgloss.Color("#4B5563"), // gray-600
		MsgBorderUser:    lipgloss.Color("#06B6D4"), // cyan
		MsgBorderAgent:   lipgloss.Color("#7C3AED"), // violet
		MsgBorderSystem:  lipgloss.Color("#374151"), // dim
		MsgBorderWarning: lipgloss.Color("#F59E0B"), // amber
		MsgBorderError:   lipgloss.Color("#EF4444"), // red
	}

	lightTheme = Theme{
		Name:             "light",
		Primary:          lipgloss.Color("#6D28D9"), // violet-700
		Secondary:        lipgloss.Color("#0891B2"), // cyan-600
		Success:          lipgloss.Color("#16A34A"), // green-600
		Warning:          lipgloss.Color("#D97706"), // amber-600
		Error:            lipgloss.Color("#DC2626"), // red-600
		Muted:            lipgloss.Color("#9CA3AF"), // gray-400
		Dim:              lipgloss.Color("#D1D5DB"), // gray-300
		Border:           lipgloss.Color("#9CA3AF"), // gray-400
		MsgBorderUser:    lipgloss.Color("#0891B2"), // cyan-600
		MsgBorderAgent:   lipgloss.Color("#6D28D9"), // violet-700
		MsgBorderSystem:  lipgloss.Color("#D1D5DB"), // gray-300
		MsgBorderWarning: lipgloss.Color("#D97706"), // amber-600
		MsgBorderError:   lipgloss.Color("#DC2626"), // red-600
	}

	catppuccinTheme = Theme{
		Name:             "catppuccin",
		Primary:          lipgloss.Color("#CBA6F7"), // mauve
		Secondary:        lipgloss.Color("#89DCEB"), // sky
		Success:          lipgloss.Color("#A6E3A1"), // green
		Warning:          lipgloss.Color("#F9E2AF"), // yellow
		Error:            lipgloss.Color("#F38BA8"), // red
		Muted:            lipgloss.Color("#6C7086"), // overlay0
		Dim:              lipgloss.Color("#45475A"), // surface1
		Border:           lipgloss.Color("#585B70"), // surface2
		MsgBorderUser:    lipgloss.Color("#89DCEB"), // sky
		MsgBorderAgent:   lipgloss.Color("#CBA6F7"), // mauve
		MsgBorderSystem:  lipgloss.Color("#45475A"), // surface1
		MsgBorderWarning: lipgloss.Color("#F9E2AF"), // yellow
		MsgBorderError:   lipgloss.Color("#F38BA8"), // red
	}
)

// Themes maps theme names to their definitions.
var Themes = map[string]Theme{
	"dark":       darkTheme,
	"light":      lightTheme,
	"catppuccin": catppuccinTheme,
}

// ThemeNames lists available themes in display order.
var ThemeNames = []string{"dark", "light", "catppuccin"}

// CurrentThemeName tracks the active theme name.
var CurrentThemeName = "dark"
