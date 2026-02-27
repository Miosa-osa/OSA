package markdown

import (
	"strings"

	"github.com/charmbracelet/glamour"
)

var renderer *glamour.TermRenderer

func init() {
	var err error
	renderer, err = glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(100),
	)
	if err != nil {
		// Fallback: return raw text if glamour fails to init.
		renderer = nil
	}
}

// Render converts markdown text to styled ANSI output.
// Falls back to raw text if the renderer is unavailable.
func Render(md string) string {
	if renderer == nil || strings.TrimSpace(md) == "" {
		return md
	}
	out, err := renderer.Render(md)
	if err != nil {
		return md
	}
	// glamour adds trailing newlines; trim for inline display.
	return strings.TrimRight(out, "\n")
}

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
