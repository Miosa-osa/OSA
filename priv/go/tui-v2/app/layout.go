package app

// LayoutMode determines the visual layout.
type LayoutMode int

const (
	LayoutCompact LayoutMode = iota // Header + Chat + Status + Input (default)
	LayoutSidebar                   // Header + [Sidebar | Chat] + Status + Input
)

const (
	// compactModeBreakpoint is the terminal width below which we force compact
	// layout regardless of user preference.
	compactModeBreakpoint = 100

	// Sidebar sizing bounds.
	sidebarMinWidth = 28
	sidebarMaxWidth = 40

	// Minimum chat pane width; enforced even if it means the sidebar is clipped.
	chatMinWidth = 50

	// minSidebarWidth is the minimum terminal width to allow sidebar layout.
	// Must accommodate sidebarMinWidth + chatMinWidth + 1 (divider).
	minSidebarWidth = sidebarMinWidth + chatMinWidth + 1
)

// Layout holds computed dimensions for the current frame.
type Layout struct {
	Mode          LayoutMode
	TermWidth     int
	TermHeight    int
	HeaderHeight  int // header line + separator
	StatusHeight  int
	InputHeight   int
	ChatWidth     int // width available for the chat pane
	ChatHeight    int // height available for the chat pane
	SidebarWidth  int // 0 in compact mode
	SidebarHeight int
	CompactMode   bool // true when the terminal is too narrow for sidebar layout
}

// ComputeLayout calculates the layout dimensions based on terminal size and mode.
//
// Responsive rules:
//   - If termW < compactModeBreakpoint, force LayoutCompact regardless of mode.
//   - Sidebar width is clamped between sidebarMinWidth and sidebarMaxWidth.
//   - Chat width is termW - sidebarWidth - 1 (divider) in sidebar mode, or
//     termW in compact mode.
//   - Heights: allocate header (1-2), input (3), status, tasks, agents; the
//     remainder goes to the chat pane.
func ComputeLayout(termW, termH int, mode LayoutMode, statusLines, taskLines, agentLines int) Layout {
	l := Layout{
		TermWidth:    termW,
		TermHeight:   termH,
		HeaderHeight: 2, // header line + separator
		InputHeight:  2, // separator + prompt line
	}

	// Status height: at least 1 line for idle state.
	l.StatusHeight = statusLines
	if l.StatusHeight < 1 {
		l.StatusHeight = 1
	}

	// Determine effective layout mode.
	effectiveMode := mode
	if termW < compactModeBreakpoint {
		effectiveMode = LayoutCompact
		l.CompactMode = true
	}

	// Sidebar dimensions.
	if effectiveMode == LayoutSidebar && termW >= minSidebarWidth {
		l.Mode = LayoutSidebar

		// Clamp sidebar width proportional to terminal width.
		sw := termW / 5 // roughly 20% of screen
		if sw < sidebarMinWidth {
			sw = sidebarMinWidth
		}
		if sw > sidebarMaxWidth {
			sw = sidebarMaxWidth
		}
		l.SidebarWidth = sw
		l.ChatWidth = termW - sw - 1 // -1 for the divider border column
	} else {
		l.Mode = LayoutCompact
		l.SidebarWidth = 0
		l.ChatWidth = termW
	}

	// Enforce minimum chat width.
	if l.ChatWidth < chatMinWidth {
		l.ChatWidth = chatMinWidth
	}

	// Chat height = total - header - status - input - tasks - agents.
	reserved := l.HeaderHeight + l.StatusHeight + l.InputHeight + taskLines + agentLines
	l.ChatHeight = termH - reserved
	if l.ChatHeight < 5 {
		l.ChatHeight = 5
	}

	l.SidebarHeight = l.ChatHeight

	return l
}
