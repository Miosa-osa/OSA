package style

import (
	"fmt"
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
)

// LerpColor linearly interpolates between two colors at position t ∈ [0,1].
// Both inputs must satisfy color.Color (RGBA). Returns an image/color.NRGBA.
func LerpColor(a, b color.Color, t float64) color.Color {
	if t <= 0 {
		return a
	}
	if t >= 1 {
		return b
	}
	ar, ag, ab, aa := a.RGBA()
	br, bg, bb, ba := b.RGBA()

	// RGBA() returns values in [0, 65535]. Convert to [0, 255].
	lerp := func(x, y uint32) uint8 {
		v := float64(x>>8)*(1-t) + float64(y>>8)*t
		if v > 255 {
			v = 255
		}
		return uint8(v)
	}

	return color.NRGBA{
		R: lerp(ar, br),
		G: lerp(ag, bg),
		B: lerp(ab, bb),
		A: lerp(aa, ba),
	}
}

// nrgbaToHex converts a color.Color to a CSS hex string "#RRGGBB".
// Alpha is ignored for terminal compatibility.
func nrgbaToHex(c color.Color) string {
	r, g, b, _ := c.RGBA()
	return fmt.Sprintf("#%02X%02X%02X", r>>8, g>>8, b>>8)
}

// GradientText renders text with a left-to-right horizontal color gradient
// from `from` to `to`, coloring each rune individually.
func GradientText(text string, from, to color.Color) string {
	runes := []rune(text)
	n := len(runes)
	if n == 0 {
		return ""
	}
	if n == 1 {
		hex := nrgbaToHex(from)
		return lipgloss.NewStyle().Foreground(lipgloss.Color(hex)).Render(string(runes))
	}

	var sb strings.Builder
	for i, r := range runes {
		t := float64(i) / float64(n-1)
		c := LerpColor(from, to, t)
		hex := nrgbaToHex(c)
		sb.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color(hex)).Render(string(r)))
	}
	return sb.String()
}

// GradientTextBold renders gradient text in bold.
func GradientTextBold(text string, from, to color.Color) string {
	runes := []rune(text)
	n := len(runes)
	if n == 0 {
		return ""
	}
	if n == 1 {
		hex := nrgbaToHex(from)
		return lipgloss.NewStyle().Foreground(lipgloss.Color(hex)).Bold(true).Render(string(runes))
	}

	var sb strings.Builder
	for i, r := range runes {
		t := float64(i) / float64(n-1)
		c := LerpColor(from, to, t)
		hex := nrgbaToHex(c)
		sb.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color(hex)).Bold(true).Render(string(r)))
	}
	return sb.String()
}

// ApplyForegroundGrad applies the default theme gradient (GradColorA → GradColorB)
// to the given text without bold.
func ApplyForegroundGrad(s string) string {
	return GradientText(s, GradColorA, GradColorB)
}

// ApplyBoldForegroundGrad applies the default theme gradient in bold.
func ApplyBoldForegroundGrad(s string) string {
	return GradientTextBold(s, GradColorA, GradColorB)
}

// ForegroundGrad is the low-level gradient function exposed for callers that
// want to supply their own color endpoints.
func ForegroundGrad(s string, a, b color.Color) string {
	return GradientText(s, a, b)
}
