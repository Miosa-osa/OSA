// Package logo provides the OSA ASCII art logo and related rendering helpers.
package logo

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// FullLogo is the full 6-line ASCII art OSA logo.
const FullLogo = ` ██████╗ ███████╗ █████╗
██╔═══██╗██╔════╝██╔══██╗
██║   ██║███████╗███████║
██║   ██║╚════██║██╔══██║
╚██████╔╝███████║██║  ██║
 ╚═════╝ ╚══════╝╚═╝  ╚═╝`

// CompactLogo is used when the terminal is too narrow for the full logo.
const CompactLogo = "◈ OSA"

// fullLogoMinWidth is the minimum terminal width to use the full logo.
const fullLogoMinWidth = 40

// Render returns the logo sized for the given width.
// Full logo if width >= fullLogoMinWidth, compact otherwise.
// The full logo is rendered in the primary theme color.
func Render(width int) string {
	if width < fullLogoMinWidth {
		return lipgloss.NewStyle().Foreground(style.Primary).Bold(true).Render(CompactLogo)
	}
	return lipgloss.NewStyle().Foreground(style.Primary).Render(FullLogo)
}

// RenderWithGradient renders the full logo (or compact fallback) with
// a left-to-right gradient using the current theme gradient colors.
func RenderWithGradient(width int) string {
	if width < fullLogoMinWidth {
		return style.ApplyBoldForegroundGrad(CompactLogo)
	}
	return renderLogoGradient()
}

// renderLogoGradient applies the theme gradient to each line of the full logo
// independently, producing a smooth horizontal sweep across all rows.
func renderLogoGradient() string {
	lines := strings.Split(FullLogo, "\n")
	result := make([]string, len(lines))
	for i, line := range lines {
		result[i] = style.ApplyForegroundGrad(line)
	}
	return strings.Join(result, "\n")
}

// RenderTagline returns the OSA tagline in a muted style.
func RenderTagline() string {
	return lipgloss.NewStyle().
		Foreground(style.Muted).
		Italic(true).
		Render("Operating System Agent — Your OS, Supercharged")
}

// RenderVersion returns "v{version}" styled with the muted theme color.
func RenderVersion(version string) string {
	v := version
	if v == "" {
		v = "v0.2.5"
	}
	if !strings.HasPrefix(v, "v") {
		v = "v" + v
	}
	return lipgloss.NewStyle().Foreground(style.Muted).Render(v)
}

// RenderBanner returns the full startup banner: logo + tagline + version,
// wrapped in a rounded box sized for width.
func RenderBanner(width int, version string) string {
	logo := RenderWithGradient(width)
	tagline := RenderTagline()
	ver := RenderVersion(version)

	boxWidth := width - 4
	if boxWidth < 40 {
		boxWidth = 40
	}
	if boxWidth > 80 {
		boxWidth = 80
	}

	var content strings.Builder
	content.WriteString(logo)
	content.WriteString("\n\n")
	content.WriteString(tagline)
	content.WriteString(fmt.Sprintf("\n  %s", ver))

	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Padding(0, 2).
		Width(boxWidth).
		Render(content.String())
}
