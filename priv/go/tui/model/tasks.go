package model

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/miosa/osa-tui/msg"
	"github.com/miosa/osa-tui/style"
)

// Task represents a single checklist item with live status.
type Task struct {
	ID         string
	Subject    string
	Status     string // "pending" | "in_progress" | "completed" | "failed"
	ActiveForm string // alternate label shown while in_progress
}

// TasksModel renders a task checklist with live completion status.
// Ctrl+O (msg.ToggleExpand) toggles the expanded detail view.
type TasksModel struct {
	tasks    []Task
	expanded bool
}

// NewTasks returns a zero-value TasksModel.
func NewTasks() TasksModel {
	return TasksModel{}
}

// SetTasks replaces the full task list.
func (m *TasksModel) SetTasks(tasks []Task) {
	m.tasks = tasks
}

// UpdateTask sets the status of the task with the given ID.
// Unknown IDs are silently ignored.
func (m *TasksModel) UpdateTask(id, status string) {
	for i := range m.tasks {
		if m.tasks[i].ID == id {
			m.tasks[i].Status = status
			return
		}
	}
}

// AddTask appends a task if not already present (by ID).
func (m *TasksModel) AddTask(t Task) {
	for _, existing := range m.tasks {
		if existing.ID == t.ID {
			return
		}
	}
	m.tasks = append(m.tasks, t)
}

// Reset clears all tasks.
func (m *TasksModel) Reset() {
	m.tasks = nil
	m.expanded = false
}

// HasTasks reports whether there is at least one task.
func (m TasksModel) HasTasks() bool {
	return len(m.tasks) > 0
}

// Init satisfies tea.Model. No I/O required on start.
func (m TasksModel) Init() tea.Cmd {
	return nil
}

// Update satisfies tea.Model.
// Handles msg.ToggleExpand to show/hide detail view.
func (m TasksModel) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	if _, ok := message.(msg.ToggleExpand); ok {
		m.expanded = !m.expanded
	}
	return m, nil
}

// View renders the task list with ⎿ connector. Returns empty when no tasks.
func (m TasksModel) View() string {
	if !m.HasTasks() {
		return ""
	}

	var b strings.Builder
	for i, t := range m.tasks {
		if i == 0 {
			b.WriteString("  ")
			b.WriteString(style.Connector.Render("⎿"))
			b.WriteString("  ")
		} else {
			b.WriteString("     ")
		}
		b.WriteString(m.renderTask(t))
		b.WriteByte('\n')
	}

	// Trim trailing newline.
	out := b.String()
	if len(out) > 0 && out[len(out)-1] == '\n' {
		out = out[:len(out)-1]
	}
	return out
}

func (m TasksModel) renderTask(t Task) string {
	switch t.Status {
	case "completed":
		return style.TaskDone.Render("✔") + " " + t.Subject

	case "in_progress":
		label := t.Subject
		if m.expanded && t.ActiveForm != "" {
			label = t.ActiveForm
		}
		return style.TaskActive.Render("◼") + " " + label

	case "failed":
		return style.TaskFailed.Render("✘") + " " + t.Subject

	default: // "pending" and anything unknown
		return style.TaskPending.Render("◻") + " " + t.Subject
	}
}
