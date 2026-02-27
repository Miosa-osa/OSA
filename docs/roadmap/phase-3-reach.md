# Phase 3: Reach & Distribution

> Target: May 2026 | Status: PLANNED

## Goal

Expand OSA's reach beyond CLI developers. Web dashboard, more channels, desktop app, better onboarding.

## Deliverables

### 3.1 Web Dashboard UI
**Gap from**: OpenClaw (Control UI + WebChat)

- [ ] Phoenix LiveView dashboard on HTTP channel
- [ ] Real-time agent status and progress
- [ ] Memory browser and search
- [ ] Session history viewer
- [ ] Swarm visualization (agent network graph)
- [ ] Budget/cost dashboard
- [ ] Configuration editor

### 3.2 Additional Messaging Channels
**Gap from**: OpenClaw (50+ channels)

Priority channels:
- [ ] Microsoft Teams
- [ ] iMessage (macOS only)
- [ ] Google Chat
- [ ] LINE
- [ ] Zalo
- [ ] WeChat
- Target: 25+ total channels

### 3.3 Rich TUI
**Gap from**: OpenClaw (rich TUI with navigation)

- [ ] Panel-based terminal UI (Ratatui-style via Elixir)
- [ ] Agent status sidebar
- [ ] Memory panel
- [ ] Scrollable conversation history
- [ ] Keyboard navigation

### 3.4 Evaluation Benchmarks
**Gap from**: OpenHands (15 benchmarks)

- [ ] SWE-bench Verified
- [ ] HumanEval / HumanEvalFix
- [ ] MBPP
- [ ] Custom multi-agent benchmark
- [ ] Automated benchmark runner
- [ ] Results dashboard

### 3.5 Auto-Generated Documentation
**Gap from**: Devin (Wiki), Devin (Search)

- [ ] Auto-generate project documentation from codebase
- [ ] Interactive code Q&A skill
- [ ] Architecture diagram generation

## Success Criteria

| Metric | Target |
|--------|--------|
| Web dashboard live | Yes |
| Messaging channels | 25+ |
| TUI panels working | Yes |
| Benchmark suite | 5+ benchmarks |
