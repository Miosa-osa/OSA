package style

import (
	"image/color"

	"charm.land/lipgloss/v2"
)

// Theme defines a complete color palette for the TUI.
type Theme struct {
	Name                                              string
	Primary, Secondary, Success, Warning, Error       color.Color
	Muted, Dim, Border                                color.Color
	MsgBorderUser, MsgBorderAgent                     color.Color
	MsgBorderSystem, MsgBorderWarning, MsgBorderError color.Color
	SidebarBg                                         color.Color

	// Extended palette
	ModalBg   color.Color // overlay/modal background
	TooltipBg color.Color // tooltip background
	InputBg   color.Color // input field background

	// Selection / dialog / button
	SelectionBg      color.Color
	DialogBg         color.Color
	ButtonActiveBg   color.Color
	ButtonActiveText color.Color

	// Gradient endpoints (A=from, B=to)
	GradA color.Color
	GradB color.Color
}

// Built-in themes.
var (
	darkTheme = Theme{
		Name:             "dark",
		Primary:          lipgloss.Color("#7C3AED"),
		Secondary:        lipgloss.Color("#06B6D4"),
		Success:          lipgloss.Color("#22C55E"),
		Warning:          lipgloss.Color("#F59E0B"),
		Error:            lipgloss.Color("#EF4444"),
		Muted:            lipgloss.Color("#6B7280"),
		Dim:              lipgloss.Color("#374151"),
		Border:           lipgloss.Color("#4B5563"),
		MsgBorderUser:    lipgloss.Color("#06B6D4"),
		MsgBorderAgent:   lipgloss.Color("#7C3AED"),
		MsgBorderSystem:  lipgloss.Color("#374151"),
		MsgBorderWarning: lipgloss.Color("#F59E0B"),
		MsgBorderError:   lipgloss.Color("#EF4444"),
		SidebarBg:        lipgloss.Color("#1F2937"),
		ModalBg:          lipgloss.Color("#111827"),
		TooltipBg:        lipgloss.Color("#1F2937"),
		InputBg:          lipgloss.Color("#111827"),
		SelectionBg:      lipgloss.Color("#312E81"),
		DialogBg:         lipgloss.Color("#1F2937"),
		ButtonActiveBg:   lipgloss.Color("#7C3AED"),
		ButtonActiveText: lipgloss.Color("#FFFFFF"),
		GradA:            lipgloss.Color("#7C3AED"),
		GradB:            lipgloss.Color("#06B6D4"),
	}

	lightTheme = Theme{
		Name:             "light",
		Primary:          lipgloss.Color("#6D28D9"),
		Secondary:        lipgloss.Color("#0891B2"),
		Success:          lipgloss.Color("#16A34A"),
		Warning:          lipgloss.Color("#D97706"),
		Error:            lipgloss.Color("#DC2626"),
		Muted:            lipgloss.Color("#9CA3AF"),
		Dim:              lipgloss.Color("#D1D5DB"),
		Border:           lipgloss.Color("#9CA3AF"),
		MsgBorderUser:    lipgloss.Color("#0891B2"),
		MsgBorderAgent:   lipgloss.Color("#6D28D9"),
		MsgBorderSystem:  lipgloss.Color("#D1D5DB"),
		MsgBorderWarning: lipgloss.Color("#D97706"),
		MsgBorderError:   lipgloss.Color("#DC2626"),
		SidebarBg:        lipgloss.Color("#F3F4F6"),
		ModalBg:          lipgloss.Color("#E5E7EB"),
		TooltipBg:        lipgloss.Color("#F3F4F6"),
		InputBg:          lipgloss.Color("#FFFFFF"),
		SelectionBg:      lipgloss.Color("#DDD6FE"),
		DialogBg:         lipgloss.Color("#F9FAFB"),
		ButtonActiveBg:   lipgloss.Color("#6D28D9"),
		ButtonActiveText: lipgloss.Color("#FFFFFF"),
		GradA:            lipgloss.Color("#6D28D9"),
		GradB:            lipgloss.Color("#0891B2"),
	}

	catppuccinTheme = Theme{
		Name:             "catppuccin",
		Primary:          lipgloss.Color("#CBA6F7"),
		Secondary:        lipgloss.Color("#89DCEB"),
		Success:          lipgloss.Color("#A6E3A1"),
		Warning:          lipgloss.Color("#F9E2AF"),
		Error:            lipgloss.Color("#F38BA8"),
		Muted:            lipgloss.Color("#6C7086"),
		Dim:              lipgloss.Color("#45475A"),
		Border:           lipgloss.Color("#585B70"),
		MsgBorderUser:    lipgloss.Color("#89DCEB"),
		MsgBorderAgent:   lipgloss.Color("#CBA6F7"),
		MsgBorderSystem:  lipgloss.Color("#45475A"),
		MsgBorderWarning: lipgloss.Color("#F9E2AF"),
		MsgBorderError:   lipgloss.Color("#F38BA8"),
		SidebarBg:        lipgloss.Color("#1E1E2E"),
		ModalBg:          lipgloss.Color("#181825"),
		TooltipBg:        lipgloss.Color("#1E1E2E"),
		InputBg:          lipgloss.Color("#181825"),
		SelectionBg:      lipgloss.Color("#313244"),
		DialogBg:         lipgloss.Color("#1E1E2E"),
		ButtonActiveBg:   lipgloss.Color("#CBA6F7"),
		ButtonActiveText: lipgloss.Color("#1E1E2E"),
		GradA:            lipgloss.Color("#CBA6F7"),
		GradB:            lipgloss.Color("#89DCEB"),
	}

	tokyoNightTheme = Theme{
		Name:             "tokyo-night",
		Primary:          lipgloss.Color("#7AA2F7"),
		Secondary:        lipgloss.Color("#7DCFFF"),
		Success:          lipgloss.Color("#9ECE6A"),
		Warning:          lipgloss.Color("#E0AF68"),
		Error:            lipgloss.Color("#F7768E"),
		Muted:            lipgloss.Color("#565F89"),
		Dim:              lipgloss.Color("#3B4261"),
		Border:           lipgloss.Color("#414868"),
		MsgBorderUser:    lipgloss.Color("#7DCFFF"),
		MsgBorderAgent:   lipgloss.Color("#7AA2F7"),
		MsgBorderSystem:  lipgloss.Color("#3B4261"),
		MsgBorderWarning: lipgloss.Color("#E0AF68"),
		MsgBorderError:   lipgloss.Color("#F7768E"),
		SidebarBg:        lipgloss.Color("#1A1B26"),
		ModalBg:          lipgloss.Color("#13141E"),
		TooltipBg:        lipgloss.Color("#1A1B26"),
		InputBg:          lipgloss.Color("#13141E"),
		SelectionBg:      lipgloss.Color("#283457"),
		DialogBg:         lipgloss.Color("#1A1B26"),
		ButtonActiveBg:   lipgloss.Color("#7AA2F7"),
		ButtonActiveText: lipgloss.Color("#13141E"),
		GradA:            lipgloss.Color("#7AA2F7"),
		GradB:            lipgloss.Color("#7DCFFF"),
	}
)

// Themes maps theme names to their definitions.
var Themes = map[string]Theme{
	"dark":        darkTheme,
	"light":       lightTheme,
	"catppuccin":  catppuccinTheme,
	"tokyo-night": tokyoNightTheme,
}

// ThemeNames lists available themes in display order.
var ThemeNames = []string{"dark", "light", "catppuccin", "tokyo-night"}

// CurrentThemeName tracks the active theme name.
var CurrentThemeName = "dark"
