package status

import (
	"fmt"

	"github.com/miosa/osa-tui/style"
)

// TodoPill renders a task progress indicator, e.g. "Tasks 3/5".
// The done count is colored with style.Success; the total with style.Primary.
func TodoPill(done, total int) string {
	if total <= 0 {
		return ""
	}
	doneStr := style.TaskDone.Render(fmt.Sprintf("%d", done))
	totalStr := style.TaskActive.Render(fmt.Sprintf("%d", total))
	return style.Faint.Render("Tasks ") + doneStr + style.Faint.Render("/") + totalStr
}

// QueuePill renders a background queue indicator, e.g. "Queue: 2".
// Returns an empty string when count is zero.
func QueuePill(count int) string {
	if count <= 0 {
		return ""
	}
	label := style.Faint.Render("Queue: ")
	val := style.TaskActive.Render(fmt.Sprintf("%d", count))
	return label + val
}
