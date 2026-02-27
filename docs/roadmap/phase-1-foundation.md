# Phase 1: Foundation Hardening

> Target: March 2026 | Status: **ACTIVE**

## Goal

Close the P0 gaps that prevent OSA from competing as a coding agent. Make the existing architecture production-solid.

## Deliverables

### 1.1 Vector Embeddings in Memory Search
**Gap from**: OpenClaw (hybrid RAG with 0.7 vector / 0.3 text weighting)

- [ ] Integrate embedding generation (Python sidecar or local model)
- [ ] SQLite vector storage for memory chunks
- [ ] Hybrid search: vector + keyword with configurable weighting
- [ ] Temporal decay for recency bias
- [ ] Benchmark: memory retrieval accuracy vs OpenClaw

### 1.2 Git-Native Coding Workflow
**Gap from**: Aider (auto-commit, auto-test, auto-lint)

- [ ] Git status/diff/log via Go.Git sidecar
- [ ] Auto-stage and commit with LLM-generated messages
- [ ] Auto-detect and run project test suite after changes
- [ ] Auto-detect and run linter after changes
- [ ] Fix-loop: detect failures → generate fix → re-run → repeat (max 3 cycles)
- [ ] New skills: `git_commit`, `git_diff`, `run_tests`, `run_lint`

### 1.3 MCP Extension Compatibility
**Gap from**: Goose (1,700+ extensions), Cline, Codex CLI

- [ ] Audit current MCP implementation against MCP spec
- [ ] Test with top 20 Goose MCP extensions
- [ ] Document MCP server configuration
- [ ] Auto-discovery improvements for community MCP servers

### 1.4 SWE-Bench Benchmark Harness
**Gap from**: Aider (SOTA), SWE-Agent (79.2%)

- [ ] Set up SWE-bench Verified evaluation environment
- [ ] Run baseline benchmark with current agent
- [ ] Identify top 5 failure patterns
- [ ] Create coding-optimized agent configuration
- [ ] Target: 30%+ on first pass

### 1.5 Test Suite Expansion
- [ ] Increase from 440+ to 600+ tests
- [ ] Add integration tests for Git workflow
- [ ] Add integration tests for memory search
- [ ] Add benchmark tests for SWE-bench patterns

## Success Criteria

| Metric | Target |
|--------|--------|
| Memory search has vector embeddings | Yes |
| Git auto-commit workflow works | Yes |
| MCP top 20 extensions compatible | Yes |
| SWE-bench first run completed | 30%+ |
| Test count | 600+ |
