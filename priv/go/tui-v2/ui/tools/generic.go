package tools

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// GenericRenderer is the fallback renderer for unregistered tool names.
// It pretty-prints JSON args/results and falls back to plain text.
//
// Example:
//
//	✓ my_tool  key="value"                       55ms
//	  │ {
//	  │   "output": "ok"
//	  │ }
type GenericRenderer struct{}

const genericMaxLines = 10

// Render implements ToolRenderer.
func (r GenericRenderer) Render(name, args, result string, opts RenderOpts) string {
	detail := prettyArgs(args)
	header := renderToolHeader(opts.Status, name, detail, opts)

	if result == "" {
		return header
	}

	rendered := prettyResult(result)
	preview := truncateLines(strings.TrimRight(rendered, "\n"), maxDisplayLines(opts.Expanded, genericMaxLines))
	body := style.ToolOutput.Render(preview)
	return renderToolBox(header+"\n"+body, opts.Width)
}

// prettyArgs returns a concise human-readable summary of the args JSON.
//
//   - Single-key map → "key=value"
//   - Multi-key map  → "3 args"
//   - Non-JSON       → raw string (truncated to 60 chars)
func prettyArgs(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}

	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err != nil {
		if len(args) > 60 {
			return args[:57] + "…"
		}
		return args
	}

	if len(m) == 0 {
		return ""
	}

	if len(m) == 1 {
		for k, v := range m {
			s, ok := v.(string)
			if !ok {
				break
			}
			if len(s) > 50 {
				s = s[:47] + "…"
			}
			return style.ToolArg.Render(k + "=" + s)
		}
	}

	return style.Faint.Render(countLabel(len(m), "arg"))
}

// prettyResult pretty-prints JSON results; falls back to plain text.
func prettyResult(result string) string {
	result = strings.TrimSpace(result)
	if !strings.HasPrefix(result, "{") && !strings.HasPrefix(result, "[") {
		return result
	}
	var buf bytes.Buffer
	if err := json.Indent(&buf, []byte(result), "", "  "); err != nil {
		return result
	}
	return buf.String()
}

// countLabel formats "1 arg" / "3 args" etc.
func countLabel(n int, word string) string {
	if n == 1 {
		return fmt.Sprintf("1 %s", word)
	}
	return fmt.Sprintf("%d %ss", n, word)
}
