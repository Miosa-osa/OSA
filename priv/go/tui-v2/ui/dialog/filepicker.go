package dialog

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/miosa/osa-tui/style"
)

// FileEntry is a single directory or file entry in the file picker.
type FileEntry struct {
	Name  string
	IsDir bool
	Size  int64
}

// FilePickerModel is a keyboard-driven file browser dialog.
//
// Emits FilePickerResult on file selection, FilePickerCancel on Esc.
type FilePickerModel struct {
	currentDir string
	entries    []FileEntry
	filtered   []FileEntry
	cursor     int
	filter     string
	offset     int
	pageSize   int

	width, height int
}

// NewFilePicker returns a FilePickerModel pointed at the user's home directory.
// Call SetDir to populate it before showing.
func NewFilePicker() FilePickerModel {
	return FilePickerModel{pageSize: 16}
}

// SetDir navigates to the given directory and populates the entry list.
// Returns an error if the path cannot be read; the model state is unchanged on error.
func (m *FilePickerModel) SetDir(path string) error {
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}

	f, err := os.Open(abs)
	if err != nil {
		return err
	}
	infos, err := f.Readdir(-1)
	f.Close()
	if err != nil {
		return err
	}

	// Build entries: directories first, then files, each sorted by name.
	var dirs, files []FileEntry
	for _, info := range infos {
		entry := FileEntry{
			Name:  info.Name(),
			IsDir: info.IsDir(),
		}
		if !info.IsDir() {
			entry.Size = info.Size()
		}
		if info.IsDir() {
			dirs = append(dirs, entry)
		} else {
			files = append(files, entry)
		}
	}
	sort.Slice(dirs, func(i, j int) bool { return dirs[i].Name < dirs[j].Name })
	sort.Slice(files, func(i, j int) bool { return files[i].Name < files[j].Name })

	m.currentDir = abs
	m.entries = append(dirs, files...)
	m.filter = ""
	m.applyFilter()
	m.cursor = 0
	m.offset = 0
	return nil
}

// SetSize updates terminal dimensions.
func (m *FilePickerModel) SetSize(w, h int) {
	m.width = w
	m.height = h
	m.pageSize = h - 12
	if m.pageSize < 4 {
		m.pageSize = 4
	}
}

func (m *FilePickerModel) applyFilter() {
	if m.filter == "" {
		m.filtered = make([]FileEntry, len(m.entries))
		copy(m.filtered, m.entries)
		return
	}
	q := strings.ToLower(m.filter)
	m.filtered = m.filtered[:0]
	for _, e := range m.entries {
		if strings.Contains(strings.ToLower(e.Name), q) {
			m.filtered = append(m.filtered, e)
		}
	}
	m.cursor = 0
	m.offset = 0
}

func (m *FilePickerModel) scrollToCursor() {
	if m.cursor < m.offset {
		m.offset = m.cursor
	}
	if m.cursor >= m.offset+m.pageSize {
		m.offset = m.cursor - m.pageSize + 1
	}
	if m.offset < 0 {
		m.offset = 0
	}
}

// ──────────────────────────────────────────────────────────────────────────────
// Update
// ──────────────────────────────────────────────────────────────────────────────

// Update handles keyboard input for the file picker.
//
//	↑/k       → move cursor up
//	↓/j       → move cursor down
//	enter     → enter directory or select file
//	backspace → go up one directory (when filter empty), otherwise remove filter char
//	esc       → emit FilePickerCancel
//	char      → append to filter
func (m FilePickerModel) Update(msg tea.Msg) (FilePickerModel, tea.Cmd) {
	kp, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return m, nil
	}

	switch kp.Code {
	case tea.KeyUp, 'k':
		if m.cursor > 0 {
			m.cursor--
			m.scrollToCursor()
		}
		return m, nil

	case tea.KeyDown, 'j':
		if m.cursor < len(m.filtered)-1 {
			m.cursor++
			m.scrollToCursor()
		}
		return m, nil

	case tea.KeyEnter:
		if m.cursor < len(m.filtered) {
			entry := m.filtered[m.cursor]
			if entry.IsDir {
				target := filepath.Join(m.currentDir, entry.Name)
				if err := m.SetDir(target); err == nil {
					// SetDir updates state in place; return the mutated value.
				}
				return m, nil
			}
			// File selected.
			path := filepath.Join(m.currentDir, entry.Name)
			return m, func() tea.Msg { return FilePickerResult{Path: path} }
		}
		return m, nil

	case tea.KeyEscape:
		return m, func() tea.Msg { return FilePickerCancel{} }

	case tea.KeyBackspace:
		if m.filter != "" {
			runes := []rune(m.filter)
			m.filter = string(runes[:len(runes)-1])
			m.applyFilter()
		} else {
			// Navigate up one directory.
			parent := filepath.Dir(m.currentDir)
			if parent != m.currentDir {
				_ = m.SetDir(parent)
			}
		}
		return m, nil

	default:
		if kp.Code >= 32 && kp.Code < 127 {
			m.filter += string(rune(kp.Code))
			m.applyFilter()
		}
		return m, nil
	}
}

// ──────────────────────────────────────────────────────────────────────────────
// View
// ──────────────────────────────────────────────────────────────────────────────

// View renders the file picker dialog.
func (m FilePickerModel) View() string {
	dw := m.width - 4
	if dw > 80 {
		dw = 80
	}
	if dw < 40 {
		dw = 40
	}

	var sb strings.Builder

	// Title + current path.
	sb.WriteString(GradientTitle("Select File"))
	sb.WriteByte('\n')
	dirLabel := style.FilePath.Render(truncatePathLeft(m.currentDir, dw-8))
	sb.WriteString(dirLabel)
	sb.WriteByte('\n')
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')

	// Filter bar.
	filterPrompt := style.DialogHelpKey.Render("Filter: ")
	filterVal := m.filter
	if filterVal == "" {
		filterVal = style.Faint.Render("type to filter...")
	} else {
		filterVal = lipgloss.NewStyle().Foreground(style.Secondary).Render(filterVal)
	}
	sb.WriteString(filterPrompt + filterVal)
	sb.WriteByte('\n')
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')

	// Entry list.
	if len(m.filtered) == 0 {
		sb.WriteString(style.Faint.Render("  No entries found"))
		sb.WriteByte('\n')
	} else {
		end := m.offset + m.pageSize
		if end > len(m.filtered) {
			end = len(m.filtered)
		}

		if m.offset > 0 {
			sb.WriteString(style.Faint.Render("  ↑ more above"))
			sb.WriteByte('\n')
		}

		for i := m.offset; i < end; i++ {
			entry := m.filtered[i]
			isCursor := i == m.cursor
			sb.WriteString(m.renderEntry(entry, isCursor))
			sb.WriteByte('\n')
		}

		if end < len(m.filtered) {
			sb.WriteString(style.Faint.Render("  ↓ more below"))
			sb.WriteByte('\n')
		}
	}

	// Help bar.
	helpItems := []HelpItem{
		{Key: "↑↓", Desc: "navigate"},
		{Key: "enter", Desc: "open/select"},
		{Key: "backspace", Desc: "up / clear filter"},
		{Key: "esc", Desc: "cancel"},
	}
	sb.WriteString(style.DiffContext.Render(strings.Repeat("─", dw-6)))
	sb.WriteByte('\n')
	sb.WriteString(RenderHelpBar(helpItems, dw-6))

	frameStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(style.Border).
		Padding(1, 2).
		Width(dw)

	termW := m.width
	if termW <= 0 {
		termW = 80
	}
	termH := m.height
	if termH <= 0 {
		termH = 40
	}

	box := frameStyle.Render(sb.String())
	return lipgloss.Place(termW, termH, lipgloss.Center, lipgloss.Center, box)
}

// renderEntry renders a single file/directory row.
func (m FilePickerModel) renderEntry(entry FileEntry, isCursor bool) string {
	cursor := "  "
	if isCursor {
		cursor = style.PlanSelected.Render("> ")
	}

	var icon, name string
	if entry.IsDir {
		icon = style.ToolHeader.Render("▶ ")
		if isCursor {
			name = lipgloss.NewStyle().Foreground(style.Secondary).Bold(true).Render(entry.Name + "/")
		} else {
			name = lipgloss.NewStyle().Foreground(style.Secondary).Render(entry.Name + "/")
		}
	} else {
		icon = "  "
		if isCursor {
			name = lipgloss.NewStyle().Foreground(style.Muted).Bold(true).Render(entry.Name)
		} else {
			name = style.Faint.Render(entry.Name)
		}
	}

	var size string
	if !entry.IsDir && entry.Size > 0 {
		size = style.Faint.Render("  " + formatSize(entry.Size))
	}

	return cursor + icon + name + size
}

// truncatePathLeft shortens a path from the left if it exceeds maxW characters.
func truncatePathLeft(path string, maxW int) string {
	if len(path) <= maxW {
		return path
	}
	if maxW <= 3 {
		return "..."
	}
	return "..." + path[len(path)-(maxW-3):]
}

// formatSize returns a human-readable file size string.
func formatSize(bytes int64) string {
	switch {
	case bytes >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(bytes)/(1<<30))
	case bytes >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(bytes)/(1<<20))
	case bytes >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(bytes)/(1<<10))
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}
