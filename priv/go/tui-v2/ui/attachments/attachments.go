// Package attachments provides a horizontal chip list of file attachments
// rendered above the input area in OSA TUI v2.
package attachments

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// FileType classifies an attached file for icon and styling purposes.
type FileType int

const (
	FileText   FileType = iota // plain text, markdown, etc.
	FileImage                  // raster/vector images
	FileCode                   // source code files
	FileBinary                 // archives, executables, libraries
)

// Attachment represents a single attached file.
type Attachment struct {
	Path     string
	Name     string // display name (basename), possibly truncated
	Size     int64
	FileType FileType
}

// Model holds the list of attachments and interactive delete-mode state.
type Model struct {
	items        []Attachment
	deleteMode   bool
	deleteCursor int
	width        int
}

// AddedMsg is sent when a file is successfully attached.
type AddedMsg struct{ Path string }

// RemovedMsg is sent when a file is removed from the list.
type RemovedMsg struct{ Path string }

// New returns an empty attachments Model.
func New() Model {
	return Model{width: 80}
}

// Add resolves the given path, reads its metadata, detects its type, and
// appends it to the attachment list. Returns an error if the file cannot be
// stat'd or if the path is already attached.
func (m *Model) Add(path string) error {
	abs, err := filepath.Abs(path)
	if err != nil {
		return fmt.Errorf("attachments: resolve %q: %w", path, err)
	}

	info, err := os.Stat(abs)
	if err != nil {
		return fmt.Errorf("attachments: stat %q: %w", abs, err)
	}
	if info.IsDir() {
		return fmt.Errorf("attachments: %q is a directory", abs)
	}

	// Deduplicate by absolute path.
	for _, a := range m.items {
		if a.Path == abs {
			return fmt.Errorf("attachments: %q already attached", abs)
		}
	}

	m.items = append(m.items, Attachment{
		Path:     abs,
		Name:     filepath.Base(abs),
		Size:     info.Size(),
		FileType: detectFileType(abs),
	})
	return nil
}

// Remove deletes the attachment at position idx (no-op if out of range).
func (m *Model) Remove(idx int) {
	if idx < 0 || idx >= len(m.items) {
		return
	}
	m.items = append(m.items[:idx], m.items[idx+1:]...)
	// Clamp cursor after removal.
	if m.deleteCursor >= len(m.items) && m.deleteCursor > 0 {
		m.deleteCursor = len(m.items) - 1
	}
}

// Clear empties the attachment list and exits delete mode.
func (m *Model) Clear() {
	m.items = m.items[:0]
	m.deleteMode = false
	m.deleteCursor = 0
}

// SetWidth informs the model of the available terminal width for wrapping.
func (m *Model) SetWidth(w int) { m.width = w }

// Paths returns the absolute paths of all attached files, for sending to the
// backend when the user submits a message.
func (m Model) Paths() []string {
	out := make([]string, len(m.items))
	for i, a := range m.items {
		out[i] = a.Path
	}
	return out
}

// Count returns the number of attached files.
func (m Model) Count() int { return len(m.items) }

// IsEmpty reports whether the attachment list is empty.
func (m Model) IsEmpty() bool { return len(m.items) == 0 }

// EnterDeleteMode activates interactive deletion, placing the cursor on the
// first chip. No-op when the list is empty.
func (m *Model) EnterDeleteMode() {
	if len(m.items) == 0 {
		return
	}
	m.deleteMode = true
	m.deleteCursor = 0
}

// ExitDeleteMode deactivates interactive deletion.
func (m *Model) ExitDeleteMode() { m.deleteMode = false }

// InDeleteMode reports whether the model is in interactive deletion mode.
func (m Model) InDeleteMode() bool { return m.deleteMode }

// Update processes keyboard input when the attachment list is focused.
//
// Bindings in delete mode:
//
//	left / h    — move cursor left
//	right / l   — move cursor right
//	enter / x   — remove the chip under the cursor
//	esc         — exit delete mode
func (m Model) Update(msg tea.Msg) (Model, tea.Cmd) {
	if !m.deleteMode || len(m.items) == 0 {
		return m, nil
	}

	kp, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}

	switch kp.Code {
	case tea.KeyLeft:
		if m.deleteCursor > 0 {
			m.deleteCursor--
		}
	case tea.KeyRight:
		if m.deleteCursor < len(m.items)-1 {
			m.deleteCursor++
		}
	case tea.KeyEnter:
		removed := m.items[m.deleteCursor].Path
		m.Remove(m.deleteCursor)
		if len(m.items) == 0 {
			m.deleteMode = false
		}
		return m, func() tea.Msg { return RemovedMsg{Path: removed} }
	case tea.KeyEscape:
		m.deleteMode = false
	case 'h':
		// vi-style left navigation
		if m.deleteCursor > 0 {
			m.deleteCursor--
		}
	case 'l':
		// vi-style right navigation
		if m.deleteCursor < len(m.items)-1 {
			m.deleteCursor++
		}
	case 'x':
		// vi-style delete
		removed := m.items[m.deleteCursor].Path
		m.Remove(m.deleteCursor)
		if len(m.items) == 0 {
			m.deleteMode = false
		}
		return m, func() tea.Msg { return RemovedMsg{Path: removed} }
	}

	return m, nil
}

// View renders the attachment chips as a single horizontal strip. Returns an
// empty string when there are no attachments.
func (m Model) View() string {
	if len(m.items) == 0 {
		return ""
	}

	var chips []string
	for i, a := range m.items {
		chips = append(chips, m.renderChip(i, a))
	}

	line := strings.Join(chips, " "+style.Faint.Render("|")+" ")

	// Prepend a paper-clip label so the row is self-labelling.
	prefix := style.Faint.Render("  Attachments: ")
	return prefix + line
}

// renderChip builds the styled string for one attachment chip.
func (m Model) renderChip(idx int, a Attachment) string {
	icon := fileIcon(a.FileType)
	name := truncateName(a.Name, 20)
	size := humanSize(a.Size)

	label := fmt.Sprintf("%s %s (%s)", icon, name, size)

	var deleteMarker string
	if m.deleteMode {
		if idx == m.deleteCursor {
			deleteMarker = " " + lipgloss.NewStyle().Foreground(style.Error).Bold(true).Render("[x]")
		} else {
			deleteMarker = " " + style.Faint.Render("[x]")
		}
	} else {
		deleteMarker = " " + style.Faint.Render("×")
	}

	// Highlight the cursor chip in delete mode.
	if m.deleteMode && idx == m.deleteCursor {
		return lipgloss.NewStyle().
			Foreground(style.Secondary).
			Bold(true).
			Render(label) + deleteMarker
	}

	return style.Faint.Render(label) + deleteMarker
}

// detectFileType infers a FileType from the file extension.
func detectFileType(path string) FileType {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".go", ".py", ".js", ".ts", ".ex", ".exs", ".rb", ".rs",
		".c", ".cpp", ".h", ".java", ".swift", ".kt":
		return FileCode
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg",
		".bmp", ".tiff":
		return FileImage
	case ".zip", ".tar", ".gz", ".bin", ".exe", ".dll", ".so", ".dylib":
		return FileBinary
	default:
		return FileText
	}
}

// fileIcon returns the appropriate Unicode icon for a FileType.
func fileIcon(ft FileType) string {
	switch ft {
	case FileImage:
		return "\U0001F5BC" // 🖼
	case FileCode:
		return "\U0001F4CE" // 📎
	case FileBinary:
		return "\U0001F4E6" // 📦
	default:
		return "\U0001F4C4" // 📄
	}
}

// truncateName clips a filename to maxLen characters, appending "…" when
// truncated to keep the chip width predictable.
func truncateName(name string, maxLen int) string {
	runes := []rune(name)
	if len(runes) <= maxLen {
		return name
	}
	return string(runes[:maxLen-1]) + "…"
}

// humanSize formats a byte count into a compact human-readable string.
func humanSize(b int64) string {
	const (
		kb = 1024
		mb = 1024 * kb
	)
	switch {
	case b >= mb:
		return fmt.Sprintf("%.1fMB", float64(b)/mb)
	case b >= kb:
		return fmt.Sprintf("%.1fKB", float64(b)/kb)
	default:
		return fmt.Sprintf("%dB", b)
	}
}
