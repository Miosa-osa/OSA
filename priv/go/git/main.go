package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// Request is a JSON-RPC request read from stdin.
type Request struct {
	ID     string          `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Response is a JSON-RPC response written to stdout.
type Response struct {
	ID     string      `json:"id"`
	Result interface{} `json:"result,omitempty"`
	Error  *RPCError   `json:"error,omitempty"`
}

// RPCError represents a JSON-RPC error object.
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// PathParams holds a path parameter (used by most methods).
type PathParams struct {
	Path string `json:"path"`
}

// BlameParams holds path + file for git_blame.
type BlameParams struct {
	Path string `json:"path"`
	File string `json:"file"`
}

// LogParams holds path + optional limit for git_log.
type LogParams struct {
	Path  string `json:"path"`
	Limit int    `json:"limit"`
}

// FileStatus represents a single changed file in git_status.
type FileStatus struct {
	Path   string `json:"path"`
	Status string `json:"status"`
}

// StatusResult is returned by git_status.
type StatusResult struct {
	Files  []FileStatus `json:"files"`
	Branch string       `json:"branch"`
	Clean  bool         `json:"clean"`
}

// DiffResult is returned by git_diff.
type DiffResult struct {
	Diff string `json:"diff"`
}

// CommitEntry represents a single commit in git_log.
type CommitEntry struct {
	Hash    string `json:"hash"`
	Author  string `json:"author"`
	Message string `json:"message"`
	Date    string `json:"date"`
}

// LogResult is returned by git_log.
type LogResult struct {
	Commits []CommitEntry `json:"commits"`
}

// BlameLine represents a single line in git_blame.
type BlameLine struct {
	Hash    string `json:"hash"`
	Author  string `json:"author"`
	Line    int    `json:"line"`
	Content string `json:"content"`
}

// BlameResult is returned by git_blame.
type BlameResult struct {
	Lines []BlameLine `json:"lines"`
}

var stdout = bufio.NewWriter(os.Stdout)

func writeResponse(resp Response) {
	data, err := json.Marshal(resp)
	if err != nil {
		log.Printf("failed to marshal response: %v", err)
		return
	}
	fmt.Fprintf(stdout, "%s\n", data)
	stdout.Flush()
}

func errorResponse(id string, code int, message string) Response {
	return Response{
		ID:    id,
		Error: &RPCError{Code: code, Message: message},
	}
}

// statusCodeString converts a go-git StatusCode to a human-readable label.
func statusCodeString(code git.StatusCode) string {
	switch code {
	case git.Unmodified:
		return "unmodified"
	case git.Untracked:
		return "untracked"
	case git.Modified:
		return "modified"
	case git.Added:
		return "added"
	case git.Deleted:
		return "deleted"
	case git.Renamed:
		return "renamed"
	case git.Copied:
		return "copied"
	case git.UpdatedButUnmerged:
		return "conflict"
	default:
		return "unknown"
	}
}

// openRepo opens a git repository rooted at path. Falls back to ".".
func openRepo(path string) (*git.Repository, error) {
	if path == "" {
		path = "."
	}
	return git.PlainOpenWithOptions(path, &git.PlainOpenOptions{DetectDotGit: true})
}

func handleGitStatus(id string, params json.RawMessage) Response {
	var p PathParams
	if params != nil {
		if err := json.Unmarshal(params, &p); err != nil {
			return errorResponse(id, -32602, fmt.Sprintf("invalid params: %v", err))
		}
	}

	repo, err := openRepo(p.Path)
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to open repo: %v", err))
	}

	wt, err := repo.Worktree()
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to get worktree: %v", err))
	}

	status, err := wt.Status()
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to get status: %v", err))
	}

	// Resolve current branch name.
	head, err := repo.Head()
	branch := "HEAD"
	if err == nil {
		if head.Name().IsBranch() {
			branch = head.Name().Short()
		} else {
			branch = head.Hash().String()[:7]
		}
	}

	files := make([]FileStatus, 0, len(status))
	for filePath, fs := range status {
		// Include any file that has a staging or worktree change.
		staging := fs.Staging
		worktree := fs.Worktree
		label := ""
		if staging != git.Unmodified && staging != git.Untracked {
			label = statusCodeString(staging)
		} else if worktree != git.Unmodified {
			label = statusCodeString(worktree)
		} else {
			continue
		}
		files = append(files, FileStatus{Path: filePath, Status: label})
	}

	return Response{
		ID: id,
		Result: StatusResult{
			Files:  files,
			Branch: branch,
			Clean:  status.IsClean(),
		},
	}
}

func handleGitDiff(id string, params json.RawMessage) Response {
	var p PathParams
	if params != nil {
		if err := json.Unmarshal(params, &p); err != nil {
			return errorResponse(id, -32602, fmt.Sprintf("invalid params: %v", err))
		}
	}

	repo, err := openRepo(p.Path)
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to open repo: %v", err))
	}

	head, err := repo.Head()
	if err != nil {
		// Repo with no commits — return empty diff.
		return Response{ID: id, Result: DiffResult{Diff: ""}}
	}

	commit, err := repo.CommitObject(head.Hash())
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to get HEAD commit: %v", err))
	}

	headTree, err := commit.Tree()
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to get HEAD tree: %v", err))
	}

	wt, err := repo.Worktree()
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to get worktree: %v", err))
	}

	// Build the diff by comparing HEAD tree against the current index/worktree.
	// go-git does not expose a direct HEAD..worktree unified diff, so we iterate
	// staged changes via Status and compare blob contents.
	status, err := wt.Status()
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to get status: %v", err))
	}

	var diffBuf []byte
	for filePath, fs := range status {
		if fs.Staging == git.Unmodified && fs.Worktree == git.Unmodified {
			continue
		}

		// Get old content from HEAD.
		oldContent := ""
		if f, err2 := headTree.File(filePath); err2 == nil {
			if content, err3 := f.Contents(); err3 == nil {
				oldContent = content
			}
		}

		// Get new content from disk.
		newContent := ""
		fullPath := filePath
		if p.Path != "" && p.Path != "." {
			fullPath = p.Path + "/" + filePath
		}
		if raw, err2 := os.ReadFile(fullPath); err2 == nil {
			newContent = string(raw)
		}

		header := fmt.Sprintf("--- a/%s\n+++ b/%s\n", filePath, filePath)
		diffBuf = append(diffBuf, []byte(header)...)
		diffBuf = append(diffBuf, buildSimpleDiff(oldContent, newContent)...)
	}

	return Response{ID: id, Result: DiffResult{Diff: string(diffBuf)}}
}

// buildSimpleDiff produces a minimal +/- diff without line-level hunk headers.
// For a full unified diff, a proper diff library is needed; this keeps the binary
// dependency-light while still being useful for diagnostics.
func buildSimpleDiff(old, new string) []byte {
	if old == new {
		return nil
	}
	var out []byte
	for _, line := range splitLines(old) {
		out = append(out, []byte("- "+line+"\n")...)
	}
	for _, line := range splitLines(new) {
		out = append(out, []byte("+ "+line+"\n")...)
	}
	return out
}

func splitLines(s string) []string {
	if s == "" {
		return nil
	}
	var lines []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			lines = append(lines, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

func handleGitLog(id string, params json.RawMessage) Response {
	var p LogParams
	if params != nil {
		if err := json.Unmarshal(params, &p); err != nil {
			return errorResponse(id, -32602, fmt.Sprintf("invalid params: %v", err))
		}
	}
	if p.Limit <= 0 {
		p.Limit = 10
	}

	repo, err := openRepo(p.Path)
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to open repo: %v", err))
	}

	head, err := repo.Head()
	if err != nil {
		// No commits yet.
		return Response{ID: id, Result: LogResult{Commits: []CommitEntry{}}}
	}

	iter, err := repo.Log(&git.LogOptions{From: head.Hash()})
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to get log: %v", err))
	}
	defer iter.Close()

	commits := make([]CommitEntry, 0, p.Limit)
	_ = iter.ForEach(func(c *object.Commit) error {
		if len(commits) >= p.Limit {
			return fmt.Errorf("stop") // sentinel to break iteration
		}
		commits = append(commits, CommitEntry{
			Hash:    c.Hash.String(),
			Author:  c.Author.Name,
			Message: c.Message,
			Date:    c.Author.When.UTC().Format(time.RFC3339),
		})
		return nil
	})

	return Response{ID: id, Result: LogResult{Commits: commits}}
}

func handleGitBlame(id string, params json.RawMessage) Response {
	var p BlameParams
	if params != nil {
		if err := json.Unmarshal(params, &p); err != nil {
			return errorResponse(id, -32602, fmt.Sprintf("invalid params: %v", err))
		}
	}
	if p.File == "" {
		return errorResponse(id, -32602, "missing required param: file")
	}

	repo, err := openRepo(p.Path)
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to open repo: %v", err))
	}

	head, err := repo.Head()
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("no HEAD: %v", err))
	}

	commit, err := repo.CommitObject(head.Hash())
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("failed to get HEAD commit: %v", err))
	}

	blame, err := git.Blame(commit, p.File)
	if err != nil {
		return errorResponse(id, -1, fmt.Sprintf("blame failed: %v", err))
	}

	lines := make([]BlameLine, 0, len(blame.Lines))
	for i, bl := range blame.Lines {
		hash := plumbing.ZeroHash.String()
		author := ""
		if bl.Hash != plumbing.ZeroHash {
			hash = bl.Hash.String()
		}
		if bl.Author != "" {
			author = bl.Author
		}
		lines = append(lines, BlameLine{
			Hash:    hash,
			Author:  author,
			Line:    i + 1,
			Content: bl.Text,
		})
	}

	return Response{ID: id, Result: BlameResult{Lines: lines}}
}

func handleRequest(req Request) Response {
	switch req.Method {
	case "ping":
		return Response{ID: req.ID, Result: "pong"}
	case "git_status":
		return handleGitStatus(req.ID, req.Params)
	case "git_diff":
		return handleGitDiff(req.ID, req.Params)
	case "git_log":
		return handleGitLog(req.ID, req.Params)
	case "git_blame":
		return handleGitBlame(req.ID, req.Params)
	default:
		return errorResponse(req.ID, -32601, fmt.Sprintf("unknown method: %s", req.Method))
	}
}

func main() {
	// Direct all library logging to stderr — stdout is protocol-only.
	log.SetOutput(os.Stderr)
	log.SetFlags(log.Ltime | log.Lshortfile)

	log.Println("osa-git sidecar ready")

	scanner := bufio.NewScanner(os.Stdin)
	// 10MB buffer to handle large diffs in a single line.
	scanner.Buffer(make([]byte, 0), 10*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			log.Printf("failed to parse request: %v", err)
			writeResponse(errorResponse("", -32700, fmt.Sprintf("parse error: %v", err)))
			continue
		}

		resp := handleRequest(req)
		writeResponse(resp)
	}

	if err := scanner.Err(); err != nil {
		log.Fatalf("stdin scanner error: %v", err)
	}

	log.Println("stdin closed, exiting")
}
