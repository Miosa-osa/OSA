#!/usr/bin/env python3
"""
Claude Code Ecosystem Health Check
Quick diagnostic for optimization system status
"""
import json
from pathlib import Path
from datetime import datetime

CLAUDE_DIR = Path.home() / '.claude'

def check_file(path: Path, name: str) -> dict:
    """Check if file exists and is valid JSON"""
    if not path.exists():
        return {"name": name, "status": "missing", "icon": "✗"}
    try:
        with open(path) as f:
            data = json.load(f)
        return {"name": name, "status": "ok", "icon": "✓", "data": data}
    except json.JSONDecodeError:
        return {"name": name, "status": "invalid", "icon": "!"}

def main():
    print("=" * 60)
    print("CLAUDE CODE ECOSYSTEM HEALTH CHECK")
    print(f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)
    print()

    # Check core files
    checks = [
        (CLAUDE_DIR / 'routing/optimization-config.json', 'Optimization Config'),
        (CLAUDE_DIR / 'routing/agent-capabilities.json', 'Agent Capabilities'),
        (CLAUDE_DIR / 'learning/config.json', 'Learning Config'),
        (CLAUDE_DIR / 'routing/swarm-patterns-v2.json', 'Swarm Patterns'),
        (CLAUDE_DIR / 'telemetry/events.jsonl', 'Telemetry Events'),
    ]

    print("Core Components:")
    all_ok = True
    for path, name in checks:
        result = check_file(path, name)
        print(f"  {result['icon']} {result['name']}: {result['status']}")
        if result['status'] != 'ok':
            all_ok = False

    print()

    # Check hooks
    hooks_dir = CLAUDE_DIR / 'hooks'
    hooks = list(hooks_dir.glob('*.py')) + list(hooks_dir.glob('*.sh'))
    print(f"Hooks: {len(hooks)} installed")
    for h in hooks:
        print(f"  - {h.name}")

    print()

    # Optimization summary
    opt_config = check_file(CLAUDE_DIR / 'routing/optimization-config.json', 'opt')
    if opt_config.get('data'):
        config = opt_config['data']
        print("Active Optimizations:")
        print(f"  - Semantic Routing: {config.get('semanticRouter', {}).get('enabled', False)}")
        print(f"  - Model Tier Routing: {config.get('modelTierRouting', {}).get('distribution', {})}")
        print(f"  - Prompt Caching: {config.get('promptCaching', {}).get('strategy', 'none')}")
        print(f"  - Context Compression: {config.get('contextCompression', {}).get('method', 'none')}")
        print(f"  - Parallel Execution: {config.get('parallelExecution', {}).get('pattern', 'none')}")

    print()

    # Agent summary
    agent_config = check_file(CLAUDE_DIR / 'routing/agent-capabilities.json', 'agents')
    if agent_config.get('data'):
        agents = agent_config['data'].get('agents', {})
        tiers = {}
        models = {}
        for a in agents.values():
            tier = a.get('tier', 'unknown')
            model = a.get('model', 'unknown')
            tiers[tier] = tiers.get(tier, 0) + 1
            models[model] = models.get(model, 0) + 1
        print(f"Agents: {len(agents)} configured")
        print(f"  By Tier: {tiers}")
        print(f"  By Model: {models}")

    print()

    # Telemetry summary
    events_file = CLAUDE_DIR / 'telemetry/events.jsonl'
    if events_file.exists():
        events = [json.loads(l) for l in events_file.read_text().strip().split('\n') if l]
        print(f"Telemetry: {len(events)} events recorded")
        event_types = {}
        for e in events:
            et = e.get('event_type', 'unknown')
            event_types[et] = event_types.get(et, 0) + 1
        for et, count in event_types.items():
            print(f"  - {et}: {count}")

    print()
    print("=" * 60)
    print(f"SYSTEM STATUS: {'HEALTHY' if all_ok else 'NEEDS ATTENTION'}")
    print("=" * 60)

if __name__ == "__main__":
    main()
