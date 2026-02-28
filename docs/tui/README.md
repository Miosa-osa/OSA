# TUI Documentation

Go-based terminal UI for OSA (`bin/osa`).

## Contents

| File | Description |
|------|-------------|
| [guide.md](guide.md) | User guide — quick start, commands, features, keybindings |
| [roadmap.md](roadmap.md) | Development history, architecture, state machine, completed features, and planned work |
| [bugs.md](bugs.md) | Known issues, pipeline audit findings, and recently fixed bugs |

## Quick Reference

```bash
# Build
cd priv/go/tui-v2 && make build

# Run
bin/osa                    # Default profile
bin/osa --dev              # Dev mode (port 19001)
bin/osa --profile staging  # Named profile

# Test
cd priv/go/tui-v2 && go build ./... && go vet ./...
```

## Architecture

```
priv/go/tui/
├── main.go              Entry point
├── app/                 Root model, state machine, keybindings
├── client/              REST + SSE client
├── model/               UI components (chat, input, activity, agents, etc.)
├── msg/                 Tea.Msg types
├── style/               Themes + Lipgloss styles
└── markdown/            Glamour renderer
```

See [roadmap.md](roadmap.md) for full architecture details and feature status.
