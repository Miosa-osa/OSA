package diff

import (
	"bytes"
	"path/filepath"
	"strings"
	"sync"

	"github.com/alecthomas/chroma/v2"
	"github.com/alecthomas/chroma/v2/formatters"
	"github.com/alecthomas/chroma/v2/lexers"
	"github.com/alecthomas/chroma/v2/styles"
	"github.com/miosa/osa-tui/style"
)

// lexerCache maps file extension strings to a coalesced chroma.Lexer.
// sync.Map is used so concurrent diff renders don't race on cache writes.
var lexerCache sync.Map // string -> chroma.Lexer

// getLexer returns a coalesced chroma.Lexer for filename. Results are cached
// by file extension so that repeated calls (e.g. per-line highlighting) avoid
// the full regex-match scan on every invocation.
func getLexer(filename string) chroma.Lexer {
	ext := strings.ToLower(filepath.Ext(filename))
	if ext == "" {
		ext = strings.ToLower(filepath.Base(filename))
	}

	if cached, ok := lexerCache.Load(ext); ok {
		return cached.(chroma.Lexer)
	}

	lexer := lexers.Match(filename)
	if lexer == nil {
		lexer = lexers.Fallback
	}
	lexer = chroma.Coalesce(lexer)
	lexerCache.Store(ext, lexer)
	return lexer
}

// chromaStyle returns the Chroma style that best matches the active OSA theme.
func chromaStyle() *chroma.Style {
	if style.IsDark() {
		s := styles.Get("monokai")
		if s != nil {
			return s
		}
	}
	s := styles.Get("github")
	if s != nil {
		return s
	}
	return styles.Fallback
}

// ttyFormatter returns the best available terminal formatter.
// We prefer terminal16m (true-colour); the formatters package registers it
// under that name via its init().
func ttyFormatter() chroma.Formatter {
	// terminal16m gives us 24-bit colour — ideal for modern terminals.
	if f := formatters.Get("terminal16m"); f != nil {
		return f
	}
	// Fallback to 256-colour.
	if f := formatters.Get("terminal256"); f != nil {
		return f
	}
	return formatters.Fallback
}

// HighlightLine applies syntax highlighting to a single line of code using
// Chroma's terminal formatter. filename is used to detect the language lexer.
// Returns the highlighted string with ANSI escape codes, or the original line
// unchanged if highlighting fails.
func HighlightLine(filename, line string) string {
	if filename == "" || line == "" {
		return line
	}

	lexer := getLexer(filename)
	// If we got the fallback lexer, skip highlighting to avoid noise.
	if lexer == lexers.Fallback {
		return line
	}

	it, err := lexer.Tokenise(nil, line+"\n")
	if err != nil {
		return line
	}

	var buf bytes.Buffer
	if err := ttyFormatter().Format(&buf, chromaStyle(), it); err != nil {
		return line
	}

	result := buf.String()
	// Strip the trailing newline we appended above.
	result = strings.TrimRight(result, "\n")
	return result
}

// HighlightBlock applies syntax highlighting to a multi-line block of code.
// filename is used to detect the language lexer.
// width is used only for truncation; highlighting is not truncated here —
// callers should truncate after highlighting via the truncate() helper.
func HighlightBlock(filename, code string, width int) string {
	if filename == "" || code == "" {
		return code
	}

	lexer := getLexer(filename)
	if lexer == lexers.Fallback {
		return code
	}

	it, err := lexer.Tokenise(nil, code)
	if err != nil {
		return code
	}

	var buf bytes.Buffer
	if err := ttyFormatter().Format(&buf, chromaStyle(), it); err != nil {
		return code
	}

	result := buf.String()

	// If width is specified, truncate each line.
	if width > 0 {
		lines := strings.Split(result, "\n")
		for i, l := range lines {
			lines[i] = truncate(l, width)
		}
		result = strings.Join(lines, "\n")
	}

	return strings.TrimRight(result, "\n")
}
