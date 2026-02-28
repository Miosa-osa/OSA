package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// TodosRenderer renders todo list tool invocations as a checklist.
//
// Example:
//
//	✓ TodoWrite  4 items                         12ms
//	  │ ✔ Setup database schema
//	  │ ◼ Implement API endpoints  (Writing...)
//	  │ ◻ Write tests
//	  │ ✘ Deploy to staging
//	  │ 2/4 complete
type TodosRenderer struct{}

// todoStatus represents the state of a single todo item.
type todoStatus int

const (
	todoPending    todoStatus = iota // ◻ not started
	todoInProgress                   // ◼ in progress
	todoCompleted                    // ✔ done
	todoFailed                       // ✘ failed
)

// todoItem is a single parsed todo entry.
type todoItem struct {
	ID       string
	Content  string
	Status   todoStatus
	Notes    string // optional in-progress note
	SubItems []todoItem
}

// Render implements ToolRenderer.
func (r TodosRenderer) Render(name, args, result string, opts RenderOpts) string {
	displayName := resolveTodosName(name)
	items := parseTodoItems(result)
	if len(items) == 0 {
		// Try parsing from args (TodoRead may have them there).
		items = parseTodoItems(args)
	}

	// Sort: in_progress first, then pending, completed, failed.
	items = sortTodos(items)

	count := len(items)
	var detail string
	if count > 0 {
		detail = style.Faint.Render(fmt.Sprintf("%d items", count))
	}

	header := renderToolHeader(opts.Status, displayName, detail, opts)

	if opts.Compact {
		return header
	}

	if len(items) == 0 {
		return header
	}

	var sb strings.Builder
	for _, item := range items {
		sb.WriteString(renderTodoItem(item) + "\n")
	}

	// Progress line: "X/Y complete".
	completed := 0
	for _, item := range items {
		if item.Status == todoCompleted {
			completed++
		}
	}
	sb.WriteString(style.Faint.Render(fmt.Sprintf("%d/%d complete", completed, count)))

	return renderToolBox(header+"\n"+sb.String(), opts.Width)
}

// renderTodoItem renders a single todo item with status icon and optional note.
func renderTodoItem(item todoItem) string {
	var icon string
	var contentStyle = style.ToolOutput
	switch item.Status {
	case todoCompleted:
		icon = style.TaskDone.Render("✔")
	case todoInProgress:
		icon = style.TaskActive.Render("◼")
		contentStyle = style.TaskActive
	case todoFailed:
		icon = style.TaskFailed.Render("✘")
	default:
		icon = style.TaskPending.Render("◻")
	}

	line := icon + " " + contentStyle.Render(item.Content)
	if item.Notes != "" && item.Status == todoInProgress {
		line += "  " + style.Faint.Render("("+item.Notes+")")
	}
	return line
}

// parseTodoItems parses todo items from JSON.
// Supported shapes:
//   - Array of objects: [{"content": "...", "status": "pending"}, ...]
//   - Object with "todos" key.
//   - Flat JSON object where values are status strings.
func parseTodoItems(raw string) []todoItem {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}

	// Try array.
	if strings.HasPrefix(raw, "[") {
		var arr []map[string]interface{}
		if err := json.Unmarshal([]byte(raw), &arr); err == nil {
			return mapToTodos(arr)
		}
	}

	// Try object with todos/items/tasks field.
	if strings.HasPrefix(raw, "{") {
		var obj map[string]interface{}
		if err := json.Unmarshal([]byte(raw), &obj); err == nil {
			for _, key := range []string{"todos", "items", "tasks", "checklist"} {
				if raw, ok := obj[key]; ok {
					if arr, ok := raw.([]interface{}); ok {
						var maps []map[string]interface{}
						for _, item := range arr {
							if m, ok := item.(map[string]interface{}); ok {
								maps = append(maps, m)
							}
						}
						if items := mapToTodos(maps); len(items) > 0 {
							return items
						}
					}
				}
			}
		}
	}

	return nil
}

// mapToTodos converts raw JSON maps into todoItem values.
func mapToTodos(arr []map[string]interface{}) []todoItem {
	var out []todoItem
	for _, m := range arr {
		item := todoItem{}

		if v, ok := m["id"].(string); ok {
			item.ID = v
		}
		for _, k := range []string{"content", "text", "title", "description", "task"} {
			if v, ok := m[k].(string); ok && v != "" {
				item.Content = v
				break
			}
		}

		statusStr, _ := m["status"].(string)
		item.Status = parseTodoStatus(statusStr)

		if v, ok := m["notes"].(string); ok {
			item.Notes = v
		} else if v, ok := m["note"].(string); ok {
			item.Notes = v
		}

		if item.Content != "" {
			out = append(out, item)
		}
	}
	return out
}

// parseTodoStatus converts a string status to a todoStatus constant.
func parseTodoStatus(s string) todoStatus {
	switch strings.ToLower(s) {
	case "completed", "done", "complete", "checked":
		return todoCompleted
	case "in_progress", "inprogress", "active", "running", "doing":
		return todoInProgress
	case "failed", "error", "blocked":
		return todoFailed
	default:
		return todoPending
	}
}

// sortTodos sorts items: in_progress first, then pending, completed, failed.
func sortTodos(items []todoItem) []todoItem {
	order := func(s todoStatus) int {
		switch s {
		case todoInProgress:
			return 0
		case todoPending:
			return 1
		case todoCompleted:
			return 2
		case todoFailed:
			return 3
		}
		return 4
	}

	// Simple insertion sort — todo lists are short.
	for i := 1; i < len(items); i++ {
		for j := i; j > 0 && order(items[j].Status) < order(items[j-1].Status); j-- {
			items[j], items[j-1] = items[j-1], items[j]
		}
	}
	return items
}

// resolveTodosName maps tool names to a display label.
func resolveTodosName(name string) string {
	switch name {
	case "TodoRead":
		return "TodoRead"
	case "TodoWrite":
		return "TodoWrite"
	default:
		return "Todos"
	}
}
