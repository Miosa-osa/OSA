package chat

import (
	"os"
	"path/filepath"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// OsaLogo is the ASCII art displayed on the welcome and connecting screens.
const OsaLogo = ` ██████╗ ███████╗ █████╗
██╔═══██╗██╔════╝██╔══██╗
██║   ██║███████╗███████║
██║   ██║╚════██║██╔══██║
╚██████╔╝███████║██║  ██║
 ╚═════╝ ╚══════╝╚═╝  ╚═╝`

// renderWelcome produces the vertically-centered welcome screen shown when
// no conversation messages exist yet.
func renderWelcome(width int, version, detail, cwd string) string {
	logoStyle := lipgloss.NewStyle().Foreground(style.Primary)
	logo := logoStyle.Render(OsaLogo)

	title := style.WelcomeTitle.Render("◈ OSA Agent  " + version)
	detailLine := style.WelcomeMeta.Render(detail)

	maxCwd := width - 10
	if maxCwd < 20 {
		maxCwd = 20
	}
	cwdPath := cwd
	if len(cwdPath) > maxCwd {
		cwdPath = truncatePath(cwdPath, maxCwd)
	}
	cwdLine := style.WelcomeCwd.Render(cwdPath)
	tip := style.WelcomeTip.Render("/help for help  ·  Ctrl+O expand  ·  Ctrl+B background")

	center := func(s string) string {
		w := lipgloss.Width(s)
		if w >= width {
			return s
		}
		pad := (width - w) / 2
		return strings.Repeat(" ", pad) + s
	}

	var lines []string
	for _, l := range strings.Split(logo, "\n") {
		lines = append(lines, center(l))
	}
	lines = append(lines, "")
	lines = append(lines, center(title))
	if detail != "" {
		lines = append(lines, center(detailLine))
	}
	if cwd != "" {
		lines = append(lines, center(cwdLine))
	}
	lines = append(lines, "")
	lines = append(lines, center(tip))

	return strings.Join(lines, "\n")
}

// truncatePath shortens a filesystem path to fit within maxWidth characters.
// Strategy: full → ~/relative → …/parent/base → …/base → hard-truncate.
func truncatePath(path string, maxWidth int) string {
	if len(path) <= maxWidth {
		return path
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" && strings.HasPrefix(path, home) {
		short := "~" + path[len(home):]
		if len(short) <= maxWidth {
			return short
		}
	}
	dir := filepath.Dir(path)
	base := filepath.Base(path)
	parent := filepath.Base(dir)
	short := "…/" + parent + "/" + base
	if len(short) <= maxWidth {
		return short
	}
	short = "…/" + base
	if len(short) <= maxWidth {
		return short
	}
	if maxWidth > 3 {
		return path[:maxWidth-1] + "…"
	}
	return path[:maxWidth]
}
