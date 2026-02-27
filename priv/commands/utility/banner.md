# /banner - Show OSA Agent Banner

Show the OSA Agent compact banner. Use this after compaction or anytime to display OSA branding.

## Usage

```
/banner         Show compact banner
/banner full    Show full animated banner
```

## Instructions

When the user runs `/banner`:

1. **Compact banner** (default): Run the compact banner script
```bash
~/.claude/scripts/osa-compact-banner.sh
```

2. **Full animated banner** (with `full` argument): Run the animated banner
```bash
~/.claude/scripts/osa-animated-banner.sh
```

Display the output to the user. The banners use dark neon cyan aesthetic with animated Unicode characters.

## Output

The compact banner shows:
- OSA Agent branding with animated spinner
- Current working directory
- Tagline "Your OS, Supercharged"

The full banner shows:
- Large ASCII art "OSA AGENT"
- Animated loading bar
- Rotating taglines
- Ecosystem capabilities (Elite agents, Combat agents, MCP servers, Skills)
