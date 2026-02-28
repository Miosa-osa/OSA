package model

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/miosa/osa-tui/style"
)

// ToastLevel classifies toast severity.
type ToastLevel int

const (
	ToastInfo ToastLevel = iota
	ToastWarning
	ToastError
)

const (
	maxToasts = 3
	toastTTL  = 4 * time.Second
)

type toast struct {
	message string
	level   ToastLevel
	expiry  time.Time
}

// ToastsModel manages a queue of auto-dismissing toast notifications.
type ToastsModel struct {
	queue []toast
}

// NewToasts creates an empty ToastsModel.
func NewToasts() ToastsModel {
	return ToastsModel{}
}

// Add enqueues a toast notification. Oldest toasts are dropped if the queue exceeds maxToasts.
func (m *ToastsModel) Add(message string, level ToastLevel) {
	m.queue = append(m.queue, toast{
		message: message,
		level:   level,
		expiry:  time.Now().Add(toastTTL),
	})
	if len(m.queue) > maxToasts {
		m.queue = m.queue[len(m.queue)-maxToasts:]
	}
}

// Tick prunes expired toasts. Call on every msg.TickMsg.
func (m *ToastsModel) Tick() {
	now := time.Now()
	alive := m.queue[:0]
	for _, t := range m.queue {
		if now.Before(t.expiry) {
			alive = append(alive, t)
		}
	}
	m.queue = alive
}

// HasToasts reports whether any toasts are visible.
func (m ToastsModel) HasToasts() bool {
	return len(m.queue) > 0
}

// View renders visible toasts as right-aligned colored lines.
func (m ToastsModel) View(termWidth int) string {
	if len(m.queue) == 0 {
		return ""
	}
	var lines []string
	for _, t := range m.queue {
		icon, color := toastIconColor(t.level)
		text := fmt.Sprintf(" %s %s ", icon, t.message)
		rendered := lipgloss.NewStyle().
			Foreground(color).
			Render(text)
		w := lipgloss.Width(rendered)
		pad := termWidth - w
		if pad < 0 {
			pad = 0
		}
		lines = append(lines, strings.Repeat(" ", pad)+rendered)
	}
	return strings.Join(lines, "\n")
}

func toastIconColor(level ToastLevel) (string, lipgloss.TerminalColor) {
	switch level {
	case ToastWarning:
		return "\u26A0", style.Warning // ⚠
	case ToastError:
		return "\u2718", style.Error // ✘
	default:
		return "\u2713", style.Success // ✓
	}
}
