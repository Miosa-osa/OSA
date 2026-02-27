# Phase 2: Developer Experience

> Target: April 2026 | Status: PLANNED

## Goal

Make OSA a world-class coding agent. Close the IDE and browser gaps. Match Aider's coding quality with our multi-agent advantage.

## Deliverables

### 2.1 Browser Automation
**Gap from**: OpenClaw (CDP/Playwright), Cline (Computer Use), Cursor (built-in browser)

- [ ] Playwright integration via Elixir port or sidecar
- [ ] Screenshot capture skill
- [ ] DOM interaction (click, fill, navigate)
- [ ] Visual verification for UI changes
- [ ] Browser context injection into agent conversations

### 2.2 IDE Integration (VS Code / LSP)
**Gap from**: Cursor (native), Cline (VS Code), Continue (VS Code + JetBrains)

- [ ] Design LSP server or VS Code extension protocol
- [ ] Implement OSA as VS Code extension backend
- [ ] File sync between IDE and OSA
- [ ] Inline code suggestions
- [ ] Chat panel integration
- [ ] Plan mode display in IDE

### 2.3 Git Worktree Isolation Per Agent
**Gap from**: Cursor (parallel agents in worktrees)

- [ ] Create git worktree per agent in swarm
- [ ] Merge strategy for parallel agent changes
- [ ] Conflict detection and resolution
- [ ] Clean up worktrees after swarm completion

### 2.4 Self-Evolving Scaffold
**Gap from**: SWE-Agent (Live-SWE-agent)

- [ ] Agent can modify its own skill definitions during execution
- [ ] Agent can create new tools based on failure patterns
- [ ] Scaffold versioning (rollback if new tools degrade performance)
- [ ] Integration with SICA learning engine

### 2.5 Approval Modes
**Gap from**: Codex CLI (read-only/auto/full), Cline (per-step approval)

- [ ] Three modes: observe (read-only), assist (auto within workspace), autonomous (full access)
- [ ] Per-tool approval configuration
- [ ] Configurable via `~/.osa/config.json`

### 2.6 Image Context Support
**Gap from**: Aider, Codex CLI

- [ ] Accept image attachments (screenshots, wireframes, diagrams)
- [ ] Pass images to multimodal LLMs
- [ ] Image-to-code generation
- [ ] Screenshot comparison (before/after)

## Success Criteria

| Metric | Target |
|--------|--------|
| Browser automation works | Yes |
| VS Code extension MVP | Yes |
| Git worktree isolation in swarms | Yes |
| SWE-bench score | 50%+ |
| Approval modes implemented | Yes |
