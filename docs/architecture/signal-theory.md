# Signal Theory

> The intelligence framework that makes OSA different from every other AI agent

## What Is Signal Theory?

Signal Theory is OSA's governing framework for communication quality. Every input and output is treated as a **Signal** — a structured unit of communication that can be classified, filtered, and optimized.

While other AI agents blindly process every message, OSA **understands** messages before acting on them.

> Source: Roberto H Luna, "Signal Theory: The Architecture of Optimal Intent Encoding" (MIOSA Research, Feb 2026)

## The 5-Tuple Signal

Every message is classified into 5 dimensions:

```
S = (Mode, Genre, Type, Format, Weight)
```

| Dimension | Question | Examples |
|-----------|----------|---------|
| **Mode** | How is it perceived? | Linguistic, Visual, Code |
| **Genre** | What form does it take? | Spec, Report, PR, ADR, Brief, Bug Report |
| **Type** | What does it do? | Direct, Inform, Commit, Decide, Express |
| **Format** | What container? | Markdown, code file, CLI output, diff |
| **Weight** | How important? | 0.0 (noise) to 1.0 (critical) |

### Example Classifications

```
"Fix the auth bug in login.ex"
  → Mode: Linguistic
  → Genre: Bug Report
  → Type: Direct (command)
  → Format: CLI text
  → Weight: 0.85

"Thanks!"
  → Mode: Linguistic
  → Genre: Acknowledgment
  → Type: Express
  → Format: CLI text
  → Weight: 0.15 (noise candidate)

"Here's the PR for the user module refactor"
  → Mode: Code
  → Genre: Pull Request
  → Type: Commit
  → Format: Markdown + diff
  → Weight: 0.90
```

## Two-Tier Noise Filtering

### Tier 1: Deterministic (< 1ms)

Pattern-matching filters that catch obvious noise instantly:
- Too short (< 3 characters)
- Duplicate of recent message
- Known greeting/acknowledgment patterns ("ok", "thanks", "cool")
- Spam patterns

### Tier 2: LLM-Based (~200ms)

For uncertain signals (weight 0.3-0.6), the classifier asks the LLM:

```
"Is this message actionable or noise?"
```

This eliminates 40-60% of messages that would waste LLM tokens on other agents.

## Communication Intelligence

OSA has 5 communication intelligence modules:

### 1. CommProfiler
Learns per-contact communication patterns:
- Preferred response length
- Technical depth preference
- Communication frequency
- Topic interests

### 2. CommCoach
Scores outbound message quality before sending:
- Clarity check
- Completeness check
- Tone appropriateness
- Signal-to-noise ratio

### 3. ConversationTracker
Tracks conversation depth across 4 levels:

```
Casual    → "Hey, what's up?"
Working   → "Can you fix this bug?"
Deep      → "Let's redesign the auth architecture"
Strategic → "We need to plan the Q3 roadmap"
```

Depth affects response detail, model selection, and context assembly.

### 4. ContactDetector
Sub-millisecond pattern matching for contact identification:
- Recognizes returning users
- Loads their communication profile
- Adjusts response style accordingly

### 5. ProactiveMonitor
Detects conversational signals:
- Silence detection (user went quiet)
- Engagement drops
- Topic drift
- Frustration signals

## 4 Governing Constraints

| Constraint | Rule | Violation Example |
|-----------|------|-------------------|
| **Shannon** (ceiling) | Don't exceed the receiver's bandwidth | 500-line explanation when 20 suffice |
| **Ashby** (repertoire) | Have enough signal variety for every situation | Prose when a table is needed |
| **Beer** (architecture) | Maintain coherent structure at every scale | Orphaned logic, structure gaps |
| **Wiener** (feedback loop) | Never broadcast without confirmation | Acting without verifying understanding |

## 6 Encoding Principles

1. **Mode-message alignment** — Sequential logic → text/code. Relational logic → tables/diagrams
2. **Genre-receiver alignment** — Match genre to receiver's competence
3. **Structure imposition** — Raw information is noise. ALWAYS structure output
4. **Redundancy proportional to noise** — More structure for complex/high-stakes context
5. **Entropy preservation** — Maximum meaning per unit of output. No filler
6. **Bandwidth matching** — Match output density to receiver's capacity

## How This Affects You

As a user, Signal Theory means:
- **Less noise** in responses — no filler phrases, no unnecessary hedging
- **Right format** — tables when tables are needed, code when code is needed
- **Right depth** — brief for simple questions, detailed for complex ones
- **Proactive intelligence** — OSA notices when you're frustrated or drifting
- **Efficient token use** — noise is filtered before it reaches the LLM

## Modules

| Module | File | Purpose |
|--------|------|---------|
| Signal Classifier | `signal/classifier.ex` | 5-tuple classification with LLM + caching |
| Noise Filter | `signal/noise_filter.ex` | Two-tier noise elimination |
| CommProfiler | `intelligence/comm_profiler.ex` | Per-contact pattern learning |
| CommCoach | `intelligence/comm_coach.ex` | Outbound quality scoring |
| ConversationTracker | `intelligence/conversation_tracker.ex` | 4-level depth tracking |
| ContactDetector | `intelligence/contact_detector.ex` | Sub-ms contact recognition |
| ProactiveMonitor | `intelligence/proactive_monitor.ex` | Engagement monitoring |
