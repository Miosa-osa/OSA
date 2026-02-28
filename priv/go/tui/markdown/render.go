package markdown

import (
	"strings"

	"github.com/charmbracelet/glamour"
)

// RenderWidth creates a width-constrained renderer and renders.
func RenderWidth(md string, width int) string {
	if strings.TrimSpace(md) == "" {
		return md
	}
	r, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(width),
	)
	if err != nil {
		return md
	}
	out, err := r.Render(md)
	if err != nil {
		return md
	}
	return strings.TrimRight(out, "\n")
}
