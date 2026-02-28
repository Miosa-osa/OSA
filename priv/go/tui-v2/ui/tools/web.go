package tools

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/miosa/osa-tui/style"
)

// ---------------------------------------------------------------------------
// WebFetchRenderer
// ---------------------------------------------------------------------------

// WebFetchRenderer renders web fetch/HTTP tool invocations.
//
// Example:
//
//	✓ WebFetch  https://api.example.com          1.2s
//	  │ (4.2KB)
//	  │ {"status": "ok", ...}
type WebFetchRenderer struct{}

const webFetchMaxLines = 15

// Render implements ToolRenderer.
func (r WebFetchRenderer) Render(name, args, result string, opts RenderOpts) string {
	url := extractURL(args)
	header := renderToolHeader(opts.Status, "WebFetch", url, opts)

	if opts.Compact {
		return header
	}

	if result == "" {
		return header
	}

	body := buildFetchBody(result, maxDisplayLines(opts.Expanded, webFetchMaxLines))
	return renderToolBox(header+"\n"+body, opts.Width)
}

// buildFetchBody formats the fetch response with a size annotation.
func buildFetchBody(result string, maxLines int) string {
	trimmed := strings.TrimSpace(result)

	// Size annotation.
	var parts []string
	if len(trimmed) > 0 {
		kb := float64(len(trimmed)) / 1024.0
		if kb >= 1 {
			parts = append(parts, style.Faint.Render(fmt.Sprintf("(%.1fKB)", kb)))
		}
	}

	preview := truncateLines(trimmed, maxLines)
	parts = append(parts, style.ToolOutput.Render(preview))
	return strings.Join(parts, "\n")
}

// ---------------------------------------------------------------------------
// WebSearchRenderer
// ---------------------------------------------------------------------------

// WebSearchRenderer renders web search tool invocations.
//
// Example:
//
//	✓ WebSearch  golang context propagation      890ms
//	  │ (5 results)
//	  │ 1. Go Context — pkg.go.dev
//	  │    The context package provides a way to carry...
//	  │ 2. Context in Go — blog.golang.org
type WebSearchRenderer struct{}

const webSearchMaxResults = 5

// Render implements ToolRenderer.
func (r WebSearchRenderer) Render(name, args, result string, opts RenderOpts) string {
	query := extractQuery(args)
	header := renderToolHeader(opts.Status, "WebSearch", query, opts)

	if opts.Compact {
		return header
	}

	if result == "" {
		return header
	}

	body := buildSearchResultsBody(result, opts.Expanded)
	return renderToolBox(header+"\n"+body, opts.Width)
}

// searchResult holds one parsed search result.
type searchResult struct {
	title   string
	url     string
	snippet string
}

// buildSearchResultsBody renders a list of search results.
func buildSearchResultsBody(result string, expanded bool) string {
	results := parseSearchResults(result)

	cap := webSearchMaxResults
	if expanded {
		cap = len(results)
	}

	if len(results) == 0 {
		// Fallback: render raw text.
		text := strings.TrimRight(result, "\n")
		return style.ToolOutput.Render(text)
	}

	countLine := style.Faint.Render(fmt.Sprintf("(%d results)", len(results)))

	visible := results
	if len(results) > cap {
		visible = results[:cap]
	}

	var sb strings.Builder
	sb.WriteString(countLine + "\n")

	for i, r := range visible {
		num := style.Faint.Render(fmt.Sprintf("%d.", i+1))
		title := style.ToolName.Render(r.title)
		line := num + " " + title
		if r.url != "" {
			line += "  " + style.Faint.Render(r.url)
		}
		sb.WriteString(line + "\n")
		if r.snippet != "" {
			sb.WriteString(style.ToolOutput.Render("   "+r.snippet) + "\n")
		}
	}

	if len(results) > cap {
		sb.WriteString(style.Faint.Render(fmt.Sprintf("... (%d more results)", len(results)-cap)))
	}

	return strings.TrimRight(sb.String(), "\n")
}

// parseSearchResults attempts to parse JSON search results in common shapes,
// falling back to line-based parsing.
func parseSearchResults(result string) []searchResult {
	result = strings.TrimSpace(result)

	// Try JSON array.
	if strings.HasPrefix(result, "[") {
		var arr []map[string]interface{}
		if err := json.Unmarshal([]byte(result), &arr); err == nil {
			var out []searchResult
			for _, item := range arr {
				sr := searchResult{}
				for _, k := range []string{"title", "name"} {
					if v, ok := item[k].(string); ok {
						sr.title = v
						break
					}
				}
				for _, k := range []string{"url", "link", "href"} {
					if v, ok := item[k].(string); ok {
						sr.url = v
						break
					}
				}
				for _, k := range []string{"snippet", "description", "body", "content"} {
					if v, ok := item[k].(string); ok {
						sr.snippet = truncateString(v, 100)
						break
					}
				}
				if sr.title != "" || sr.url != "" {
					out = append(out, sr)
				}
			}
			if len(out) > 0 {
				return out
			}
		}
	}

	// Try JSON object with results field.
	if strings.HasPrefix(result, "{") {
		var obj map[string]interface{}
		if err := json.Unmarshal([]byte(result), &obj); err == nil {
			for _, k := range []string{"results", "items", "organic_results"} {
				if arr, ok := obj[k].([]interface{}); ok {
					var out []searchResult
					for _, item := range arr {
						if m, ok := item.(map[string]interface{}); ok {
							sr := searchResult{}
							for _, tk := range []string{"title", "name"} {
								if v, ok := m[tk].(string); ok {
									sr.title = v
									break
								}
							}
							for _, uk := range []string{"url", "link"} {
								if v, ok := m[uk].(string); ok {
									sr.url = v
									break
								}
							}
							for _, sk := range []string{"snippet", "description"} {
								if v, ok := m[sk].(string); ok {
									sr.snippet = truncateString(v, 100)
									break
								}
							}
							if sr.title != "" || sr.url != "" {
								out = append(out, sr)
							}
						}
					}
					if len(out) > 0 {
						return out
					}
				}
			}
		}
	}

	return nil
}

// ---------------------------------------------------------------------------
// Shared web helpers
// ---------------------------------------------------------------------------

// extractURL parses the URL from JSON args.
func extractURL(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err == nil {
		for _, key := range []string{"url", "uri", "endpoint", "input"} {
			if v, ok := m[key].(string); ok && v != "" {
				return v
			}
		}
	}
	return args
}

// extractQuery parses the search query from JSON args.
func extractQuery(args string) string {
	args = strings.TrimSpace(args)
	if args == "" {
		return ""
	}
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(args), &m); err == nil {
		for _, key := range []string{"query", "q", "search_query", "input"} {
			if v, ok := m[key].(string); ok && v != "" {
				return v
			}
		}
	}
	return args
}

// truncateString clips s to at most n runes, appending "…" if clipped.
func truncateString(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n-1]) + "…"
}
