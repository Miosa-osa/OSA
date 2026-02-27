# Aider

> Threat Level: **HIGH** | 30K+ GitHub Stars | Python | Apache 2.0

## Overview

Open-source AI pair programming tool for the terminal. SOTA on SWE-Bench. Created by Paul Gauthier. The gold standard for CLI-based AI coding.

## Key Features

- Repository-level multi-file refactors and debugging
- 100+ coding language support
- Auto-stages and commits with descriptive messages
- Auto-runs linters and tests, fixes detected problems
- Image and web page context (screenshots, reference docs)
- Voice input support
- IDE integration via source file comments

## LLM Support

Claude 3.7 Sonnet, DeepSeek R1 & Chat V3, OpenAI o1/o3-mini/GPT-4o, Ollama, nearly any LLM.

## What They Have That We Don't

| Feature | Priority | Notes |
|---------|----------|-------|
| SOTA SWE-Bench performance | HIGH | We need benchmarks |
| Git-native auto-commit | MEDIUM | Auto-stage, commit, test cycle |
| Auto-lint and auto-test cycle | HIGH | Run tests, detect failures, auto-fix |
| Voice input | LOW | Spacebar-to-talk |
| Image context (screenshots) | MEDIUM | Paste screenshots for context |

## What We Have That They Don't

| Feature | Our Advantage |
|---------|---------------|
| Multi-agent orchestration | They are single-agent only |
| Persistent memory & learning | They have zero memory between sessions |
| Signal Theory | No message intelligence |
| 18 LLM providers | They support many but no Chinese providers |
| 12+ messaging channels | They are terminal-only |
| Swarm patterns (10 presets) | No parallel execution |
| Hook pipeline | No middleware system |
| Budget/cost management | No token tracking |
| Sandboxing | No isolation |
| MCP support | No MCP |

## Assessment

Aider is the strongest pure CLI coding agent. Our path to compete: implement SWE-Bench-class coding capabilities on top of our multi-agent architecture. Their single-agent limitation is their ceiling.

## Sources

- [GitHub](https://github.com/Aider-AI/aider)
- [Website](https://aider.chat/)
