# CLI Channel

> Built-in interactive terminal — always available

## Overview

The CLI is OSA's primary interface. No configuration needed.

## Features

- Readline-like history and line editing
- Markdown-to-ANSI rendering in responses
- Progress spinners and task display
- Auto-completion for `/commands`
- Session persistence across restarts
- Plan formatting and review display

## Entry Points

```bash
osagent              # Interactive chat (default)
osagent serve        # Headless HTTP API mode (no CLI)
osagent setup        # Configuration wizard
osagent version      # Print version
```

## Configuration

```bash
# Optional
OSA_CLI_PROMPT="osa> "      # Custom prompt string
OSA_CLI_HISTORY=1000        # History size (default: 500)
```

## Key Bindings

| Key | Action |
|-----|--------|
| `Enter` | Send message |
| `Up/Down` | History navigation |
| `Tab` | Auto-complete commands |
| `Ctrl+C` | Cancel current response |
| `Ctrl+D` | Exit |
