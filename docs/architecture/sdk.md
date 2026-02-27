# MIOSA SDK Architecture
**Version:** 0.1.0-draft
**Date:** 2026-02-24
**Status:** Proposed
**Author:** Architect (OSA Agent)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Context](#2-system-context)
3. [Architecture Decision Records](#3-architecture-decision-records)
4. [SDK Interface Design](#4-sdk-interface-design)
5. [Transport Layer](#5-transport-layer)
6. [Authentication Model](#6-authentication-model)
7. [Feature Matrix](#7-feature-matrix)
8. [Package Structure](#8-package-structure)
9. [OSA HTTP API Contract](#9-osa-http-api-contract)
10. [Migration Path](#10-migration-path)
11. [Dependency Diagram](#11-dependency-diagram)

---

## 1. Executive Summary

The MIOSA SDK is the programmatic bridge between **OS Templates** (BusinessOS, ContentOS, and future custom templates built with Svelte/Go) and the **OptimalSystemAgent** (OSA) Elixir/OTP intelligence layer.

There are two editions:

| Edition | Audience | Delivery |
|---|---|---|
| **Open-source SDK** | Community, self-hosters, indie developers | GitHub, package registries |
| **MIOSA SDK (Proprietary)** | Business customers, enterprise | MIOSA Cloud, private registry |

The open-source edition provides the full agent loop, signal classification, built-in skills, machines configuration, JSONL memory, and local SSE streaming. The proprietary MIOSA SDK adds the SORX skill engine (4-tier reliability model), the CARRIER high-performance bridge (Go-Elixir AMQP), L3-L5 autonomous behavior, cross-OS reasoning, and enterprise governance.

**The critical insight:** both editions share an identical developer interface. An OS Template written against the open-source SDK upgrades to full MIOSA capability by changing one configuration line — no code changes.

---

## 2. System Context

### 2.1 Current State (as of 2026-02-24)

```
BusinessOS (Go + Svelte)
    └── internal/integrations/osa/
        ├── client.go           HTTP client, POST /api/orchestrate
        ├── resilient_client.go Circuit breaker (5 failures → open)
        │                       Exponential backoff, stale cache
        │                       Request queue (1000 max)
        ├── auth.go             JWT HS256, issuer="BusinessOS", 15min TTL
        └── types.go            AppGenerationRequest, OrchestrateRequest

OSA (Elixir/OTP)
    ├── agent/loop.ex           ReAct loop, max 30 iterations
    ├── signal/classifier.ex    S=(M,G,T,F,W) 5-tuple
    ├── skills/registry.ex      Hot-reload, SKILL.md, goldrush dispatch
    ├── machines.ex             Core/Communication/Productivity/Research
    ├── bridge/pubsub.ex        3-tier goldrush → PubSub bridge
    └── channels/cli.ex         ONLY channel today (no HTTP endpoint)
```

**The gap:** OSA has no HTTP endpoint. All intelligence is accessible only through the CLI channel. The SDK must define what OSA exposes over the wire, and how BOS (and future OS Templates) consume it.

### 2.2 Target Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        OS TEMPLATES LAYER                           │
│                                                                     │
│  BusinessOS (Go/Svelte)    ContentOS (Go/Svelte)   Custom Template  │
│       ↓                           ↓                      ↓          │
│  miosa-sdk-go          miosa-sdk-go / miosa-sdk-js   any SDK        │
└─────────────────────────────────────────────────────────────────────┘
                              ↓ HTTP / SSE / AMQP
┌─────────────────────────────────────────────────────────────────────┐
│                          SDK TRANSPORT LAYER                        │
│                                                                     │
│  Local Mode: HTTP → localhost:8089   Cloud Mode: HTTPS → api.miosa  │
│  Premium:    CARRIER (AMQP, Go↔Elixir)                             │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│                   OPTIMALSYSTEMAGENT (Elixir/OTP)                   │
│                                                                     │
│  HTTP Channel (new)    CLI Channel (existing)    Future: Telegram   │
│       ↓                                                             │
│  Agent.Loop → Signal.Classifier → Skills.Registry → Machines       │
│  Memory (JSONL) → Events.Bus → Bridge.PubSub → SSE stream          │
│                                                                     │
│  MIOSA Premium adds:                                                │
│  SORX Engine (Go) ←── CARRIER (AMQP) ──→ OSA Intelligence          │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Architecture Decision Records

### ADR-001: OSA HTTP Transport — Plug/Bandit (not Phoenix Web)

**Status:** Accepted
**Date:** 2026-02-24

**Context:**
OSA needs to expose an HTTP API. Bandit is already a compiled dependency in the OSA `_build`. Phoenix is already used for PubSub only.

**Decision:**
Add a `Plug.Router`-based HTTP channel adapter served by Bandit on port 8089. Do not introduce Phoenix Router/LiveView. Use Phoenix.PubSub (already running) to bridge agent events to SSE connections.

**Consequences:**
- Positive: Minimal surface area. Bandit already present. Zero framework overhead.
- Positive: The HTTP channel is just another channel adapter — symmetrical with CLI, Telegram, etc.
- Negative: No Phoenix Router conveniences (parameter parsing, etc.) — must implement manually via Plug.
- Neutral: SSE is implemented as a long-lived Plug connection flushing PubSub broadcasts.

**Alternatives Considered:**
- Full Phoenix Web: Rejected. Over-engineered for an API-only use case.
- Cowboy directly: Rejected. Lower ergonomics, no advantage over Plug/Bandit.

---

### ADR-002: CARRIER Transport — AMQP over RabbitMQ

**Status:** Proposed
**Date:** 2026-02-24

**Context:**
CARRIER is the premium Go-Elixir bridge for SORX Tier 3-4 skills. It needs high throughput, durable delivery, and back-pressure. Sprint 5 target.

**Decision:**
Use AMQP 0-9-1 (RabbitMQ) as the CARRIER transport. Go uses `github.com/rabbitmq/amqp091-go`. Elixir uses `AMQP` hex package. Exchange topology: `osa.commands` (direct), `osa.events` (topic).

**Consequences:**
- Positive: Proven in Go-Elixir interop. AMQP has durable queues for guaranteed delivery.
- Positive: Decouples SORX Engine (Go) from OSA process lifecycle.
- Negative: RabbitMQ adds operational complexity (another process to run locally).
- Neutral: For local mode, RabbitMQ runs in Docker. For cloud, managed RabbitMQ.

**Alternatives Considered:**
- gRPC bidirectional: Lower latency, but protobuf schema overhead and no durable delivery for async skills.
- NATS JetStream: Lighter operationally; viable future migration. Rejected now because AMQP is better understood by the existing team.

---

### ADR-003: SDK Package Strategy — Language-Specific Repos with Shared Types

**Status:** Proposed
**Date:** 2026-02-24

**Context:**
Three SDK clients are needed: Go (BOS backend), TypeScript (frontend templates), Elixir (OSA-to-OSA). They must share API type definitions and stay synchronized.

**Decision:**
Three separate repositories with independent versioning. Types are defined in an OpenAPI 3.1 spec (`osa-api-spec`) and code-generated into each language. Versioning is SemVer with a shared minor version bump policy (all three SDKs cut the same minor version together; patch versions are independent).

**Consequences:**
- Positive: Language-native packages installable from standard registries (pkg.go.dev, npm, hex.pm).
- Positive: OpenAPI spec is the single source of truth — prevents drift.
- Negative: Three repos to maintain. Requires codegen discipline.
- Neutral: Initial development uses a monorepo layout under `miosa-sdk/`; splits to independent repos at v0.1.0 stable.

---

### ADR-004: Open-Source vs. Proprietary Feature Split

**Status:** Accepted
**Date:** 2026-02-24

**Context:**
Need to define a clear, defensible boundary between what is free and what is premium. The boundary should not create "crippled free tier" perception, but should be meaningful enough to drive upgrades.

**Decision:**
The open-source SDK is fully functional for single-user local use. The premium line is drawn at: enterprise-scale throughput (SORX), proactive autonomy (L3+), cross-OS coordination, cloud hosting, and compliance tooling. This is the classic open-core model.

**Consequences:**
- Positive: Free tier is genuinely useful, builds trust and community.
- Positive: Premium features map to enterprise problems (compliance, scale, proactive monitoring).
- Negative: SORX tiers 3-4 are only in premium — power users who want AI-driven skill generation must upgrade.
- Neutral: Autonomy levels are gated: L1-L2 free, L3-L5 premium.

---

## 4. SDK Interface Design

The SDK presents a unified interface regardless of transport mode (local HTTP, cloud HTTPS, or CARRIER/AMQP). The interface is designed around the OSA's core concepts: signals, skills, machines, memory, and events.

### 4.1 Core Concepts (Language-Agnostic)

```
OSAClient
├── Agent Operations
│   ├── orchestrate(input, opts)      → AgentResponse       // Full ReAct loop
│   ├── stream(input, opts)           → EventStream         // SSE streaming
│   └── classify(message, channel)   → Signal              // S=(M,G,T,F,W)
│
├── Skill Operations
│   ├── execute_skill(skill_id, params, opts)  → Execution  // Run a skill
│   ├── get_execution(execution_id)            → Execution  // Poll status
│   └── list_skills()                          → []Skill    // Discover skills
│
├── Memory Operations
│   ├── remember(key, value, opts)    → MemoryEntry        // Save to memory
│   ├── recall(key)                   → MemoryEntry        // Retrieve exact
│   └── search(query, opts)           → []MemoryEntry      // Semantic search
│
├── Configuration
│   ├── get_machines()                → []Machine          // Active machines
│   ├── set_machines(config)          → void               // Toggle machines
│   └── set_autonomy(level)          → void               // L1-L5 (L3+ premium)
│
└── Events
    ├── subscribe(event_type, handler) → Subscription      // SSE callback
    └── health()                       → HealthStatus      // System status
```

### 4.2 Go Client (BOS Backend)

The Go SDK replaces `internal/integrations/osa/` entirely. The `ResilientClient` pattern is preserved but abstracted behind the SDK interface.

```go
// Package osa provides the MIOSA SDK Go client.
// Open-source edition — local OSA connection.
package osa

import (
    "context"
    "iter"
)

// Client is the unified OSA interface.
// Identical API for local and cloud modes — mode is a config concern.
type Client interface {
    // Agent operations
    Orchestrate(ctx context.Context, req OrchestrateRequest) (*AgentResponse, error)
    Stream(ctx context.Context, req OrchestrateRequest) iter.Seq2[Event, error]
    Classify(ctx context.Context, message string, channel Channel) (*Signal, error)

    // Skill operations
    ExecuteSkill(ctx context.Context, req SkillExecuteRequest) (*Execution, error)
    GetExecution(ctx context.Context, executionID string) (*Execution, error)
    ListSkills(ctx context.Context) ([]SkillDefinition, error)

    // Memory operations
    Remember(ctx context.Context, req RememberRequest) (*MemoryEntry, error)
    Recall(ctx context.Context, key string) (*MemoryEntry, error)
    SearchMemory(ctx context.Context, req MemorySearchRequest) ([]MemoryEntry, error)

    // Configuration
    GetMachines(ctx context.Context) ([]Machine, error)
    SetMachines(ctx context.Context, config MachineConfig) error

    // Events
    Subscribe(ctx context.Context, eventType EventType, handler EventHandler) (Subscription, error)
    Health(ctx context.Context) (*HealthStatus, error)

    // Lifecycle
    Close() error
}

// NewLocalClient creates a client connected to a local OSA instance.
// Uses HTTP on localhost:8089 with shared-secret JWT.
// This replaces the current internal/integrations/osa/ package.
func NewLocalClient(cfg LocalConfig) (Client, error)

// NewCloudClient creates a client connected to MIOSA cloud.
// Requires a MIOSA_API_KEY. Proprietary edition only.
func NewCloudClient(cfg CloudConfig) (Client, error) // premium

// --- Core Request/Response Types ---

type OrchestrateRequest struct {
    Input       string                 `json:"input"`
    UserID      string                 `json:"user_id"`
    WorkspaceID string                 `json:"workspace_id,omitempty"`
    SessionID   string                 `json:"session_id,omitempty"` // for continuity
    Context     map[string]interface{} `json:"context,omitempty"`
    Machines    []string               `json:"machines,omitempty"`   // override active machines
}

type AgentResponse struct {
    SessionID     string                 `json:"session_id"`
    Output        string                 `json:"output"`
    Signal        Signal                 `json:"signal"`
    SkillsUsed    []string               `json:"skills_used,omitempty"`
    IterationCount int                   `json:"iteration_count"`
    ExecutionMS   int64                  `json:"execution_ms"`
    Metadata      map[string]interface{} `json:"metadata,omitempty"`
}

type Signal struct {
    Mode      string  `json:"mode"`    // execute|assist|analyze|build|maintain
    Genre     string  `json:"genre"`   // direct|inform|commit|decide|express
    Type      string  `json:"type"`    // question|issue|scheduling|summary|general
    Format    string  `json:"format"`  // message|document|notification|command|transcript
    Weight    float64 `json:"weight"`  // 0.0-1.0 Shannon information content
    Channel   string  `json:"channel"`
    Timestamp string  `json:"timestamp"`
}

type SkillExecuteRequest struct {
    SkillID     string                 `json:"skill_id"`
    UserID      string                 `json:"user_id"`
    Params      map[string]interface{} `json:"params"`
    Temperature string                 `json:"temperature,omitempty"` // cold|warm|hot
    Async       bool                   `json:"async,omitempty"`
}

type Execution struct {
    ID          string                 `json:"id"`
    SkillID     string                 `json:"skill_id"`
    Status      string                 `json:"status"`     // pending|running|waiting_callback|complete|failed
    Progress    float64                `json:"progress"`   // 0.0-1.0
    CurrentStep int                    `json:"current_step"`
    TotalSteps  int                    `json:"total_steps"`
    Result      map[string]interface{} `json:"result,omitempty"`
    Error       string                 `json:"error,omitempty"`
    StartedAt   string                 `json:"started_at"`
    CompletedAt string                 `json:"completed_at,omitempty"`
}

// LocalConfig for connecting to a local OSA instance.
// All fields that exist in internal/integrations/osa/Config are preserved.
type LocalConfig struct {
    BaseURL      string        // default: "http://localhost:8089"
    SharedSecret string        // JWT shared secret (same as today)
    Timeout      time.Duration // default: 30s
    Resilience   ResilienceConfig
}

type ResilienceConfig struct {
    CircuitBreakerThreshold int           // failures before open (default: 5)
    MaxRetryTime            time.Duration // total retry window (default: 30s)
    QueueSize               int           // queued requests when open (default: 1000)
    CacheTTL                time.Duration // stale response TTL (default: 5min)
}
```

### 4.3 TypeScript/JavaScript Client (Frontend Templates)

The JS SDK is designed for use in SvelteKit and browser environments. It provides reactive stores compatible with Svelte's reactivity model.

```typescript
// @miosa/sdk — TypeScript client
// Works in browser and Node.js environments.

export interface OSAClient {
  // Agent operations
  orchestrate(req: OrchestrateRequest): Promise<AgentResponse>;
  stream(req: OrchestrateRequest): AsyncGenerator<Event>;
  classify(message: string, channel?: Channel): Promise<Signal>;

  // Skill operations
  executeSkill(req: SkillExecuteRequest): Promise<Execution>;
  getExecution(executionId: string): Promise<Execution>;
  listSkills(): Promise<SkillDefinition[]>;

  // Memory operations
  remember(req: RememberRequest): Promise<MemoryEntry>;
  recall(key: string): Promise<MemoryEntry | null>;
  searchMemory(req: MemorySearchRequest): Promise<MemoryEntry[]>;

  // Events — SSE subscription
  subscribe(eventType: EventType, handler: EventHandler): Unsubscribe;

  // Config
  getMachines(): Promise<Machine[]>;
  health(): Promise<HealthStatus>;
}

export function createClient(config: ClientConfig): OSAClient;

// Svelte store integration
// Returns a Svelte-compatible readable store wrapping agent state.
export function createAgentStore(client: OSAClient): AgentStore;

export interface AgentStore {
  // Svelte readable stores
  readonly status: Readable<AgentStatus>;       // idle|thinking|executing
  readonly lastResponse: Readable<AgentResponse | null>;
  readonly activeExecution: Readable<Execution | null>;

  // Actions
  send(input: string, context?: Record<string, unknown>): Promise<void>;
  cancel(): void;
}

export interface ClientConfig {
  // Local mode: connect to localhost OSA instance
  mode: 'local';
  baseUrl?: string;         // default: 'http://localhost:8089'
  sharedSecret: string;     // JWT shared secret

  // OR cloud mode (proprietary)
  // mode: 'cloud';
  // apiKey: string;

  userId: string;
  workspaceId?: string;
}

// Core types mirror the Go SDK exactly — generated from the same OpenAPI spec.
export interface OrchestrateRequest {
  input: string;
  userId: string;
  workspaceId?: string;
  sessionId?: string;
  context?: Record<string, unknown>;
  machines?: string[];
}

export interface AgentResponse {
  sessionId: string;
  output: string;
  signal: Signal;
  skillsUsed?: string[];
  iterationCount: number;
  executionMs: number;
  metadata?: Record<string, unknown>;
}

export interface Signal {
  mode: 'execute' | 'assist' | 'analyze' | 'build' | 'maintain';
  genre: 'direct' | 'inform' | 'commit' | 'decide' | 'express';
  type: string;
  format: 'message' | 'document' | 'notification' | 'command' | 'transcript';
  weight: number;
  channel: string;
  timestamp: string;
}

// SSE event types
export type EventType =
  | 'agent.thinking'
  | 'agent.response'
  | 'agent.error'
  | 'skill.started'
  | 'skill.step_completed'
  | 'skill.completed'
  | 'skill.failed'
  | 'skill.waiting_decision'
  | 'memory.saved'
  | 'signal.classified'
  | 'signal.filtered';

export interface Event {
  type: EventType;
  sessionId?: string;
  executionId?: string;
  data: Record<string, unknown>;
  timestamp: string;
}
```

### 4.4 Elixir Client (OSA-to-OSA Communication)

The Elixir SDK is used when one OSA instance delegates to another — for example, a specialized OSA instance handling a specific domain while the primary OSA handles orchestration.

```elixir
# miosa_sdk — Elixir/Hex package
# Enables OSA-to-OSA federation and cross-instance skill calls.

defmodule MiosaSDK do
  @moduledoc """
  MIOSA SDK Elixir client.

  Usage in another Elixir application or OSA instance:

      {:ok, client} = MiosaSDK.connect(base_url: "http://localhost:8089",
                                        shared_secret: "secret")

      {:ok, response} = MiosaSDK.orchestrate(client, %{
        input: "Analyze Q4 pipeline",
        user_id: "user_123"
      })
  """

  @type client :: %MiosaSDK.Client{}

  @spec connect(keyword()) :: {:ok, client()} | {:error, term()}
  def connect(opts)

  @spec orchestrate(client(), map()) :: {:ok, map()} | {:error, term()}
  def orchestrate(client, request)

  @spec stream(client(), map(), (map() -> :ok)) :: {:ok, reference()} | {:error, term()}
  def stream(client, request, event_handler)

  @spec classify(client(), String.t(), atom()) :: {:ok, map()} | {:error, term()}
  def classify(client, message, channel \\ :http)

  @spec execute_skill(client(), map()) :: {:ok, map()} | {:error, term()}
  def execute_skill(client, request)

  @spec get_execution(client(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_execution(client, execution_id)

  @spec remember(client(), map()) :: {:ok, map()} | {:error, term()}
  def remember(client, request)

  @spec recall(client(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def recall(client, key)

  @spec health(client()) :: {:ok, map()} | {:error, term()}
  def health(client)
end
```

---

## 5. Transport Layer

### 5.1 Mode Selection

```
ClientConfig.mode
├── "local"  → HTTP/SSE to localhost:8089
│              JWT HS256, shared secret
│              All open-source features
│
├── "cloud"  → HTTPS/SSE to api.miosa.ai   [PREMIUM]
│              API key + OAuth2 for enterprise
│              Multi-tenant workspace isolation
│
└── "carrier" → AMQP to localhost/cloud     [PREMIUM, Sprint 5]
               RabbitMQ exchange topology
               Used for SORX Tier 3-4 only
               Falls back to HTTP for standard operations
```

### 5.2 Local Mode (HTTP/SSE)

```
OS Template (Go/JS)                OSA (Elixir/Bandit)
      │                                    │
      │  POST /api/v1/orchestrate          │
      │  Authorization: Bearer <jwt>       │
      │─────────────────────────────────→  │
      │                                    │  Agent.Loop.process_message/2
      │  200 OK { output, signal, ... }    │
      │←─────────────────────────────────  │
      │                                    │
      │  GET /api/v1/stream?session_id=X   │
      │  Accept: text/event-stream         │
      │─────────────────────────────────→  │
      │  (long-lived SSE connection)       │  Bridge.PubSub.subscribe_session/1
      │  event: agent.thinking             │
      │  data: {"iteration": 1, ...}       │
      │←─────────────────────────────────  │
      │  event: skill.started              │
      │  data: {"skill_id": "...", ...}    │
      │←─────────────────────────────────  │
      │  event: agent.response             │
      │  data: {"output": "...", ...}      │
      │←─────────────────────────────────  │
```

### 5.3 Cloud Mode (HTTPS — Premium)

Identical API surface as local mode. The SDK automatically:
- Replaces `http://localhost:8089` with `https://api.miosa.ai`
- Replaces HS256 JWT with API key header (`X-MIOSA-Key`)
- Adds `X-Tenant-ID` for multi-tenant isolation
- Handles TLS certificate validation
- Routes to the user's assigned OSA instance

### 5.4 CARRIER Bridge (AMQP — Premium, Sprint 5)

CARRIER is not a replacement for HTTP. It is a supplemental high-performance channel activated specifically for SORX Tier 3-4 skill executions. Standard orchestrate/classify calls always go over HTTP.

```
BOS Backend (Go)                RabbitMQ                OSA (Elixir)
      │                            │                         │
      │  SORX Tier 3-4 skill       │                         │
      │  ExecuteSkill(req)         │                         │
      │  CARRIER.Publish(...)      │                         │
      │────────────────────────→  │                         │
      │                            │  osa.commands queue     │
      │                            │─────────────────────→   │
      │                            │                         │  Skills.Registry.execute/2
      │                            │  osa.events topic       │
      │                            │←─────────────────────   │
      │  CARRIER.Subscribe(...)    │                         │
      │←────────────────────────  │                         │
```

**Exchange topology:**

```
Exchange: osa.commands (direct)
  Routing keys:
    skill.execute       → queue: osa.skill_commands
    skill.cancel        → queue: osa.skill_commands
    memory.save         → queue: osa.memory_ops
    config.update       → queue: osa.config_ops

Exchange: osa.events (topic)
  Routing keys:
    skill.*             → binds to: skill events (started, completed, failed)
    agent.*             → binds to: agent events (thinking, response)
    memory.*            → binds to: memory events
    system.*            → binds to: system events (health, error)
```

### 5.5 SSE Event Stream Format

All SSE events follow the standard format with typed payloads:

```
event: skill.started
id: evt_01JMXYZ
data: {
  "type": "skill.started",
  "session_id": "sess_abc",
  "execution_id": "exec_123",
  "data": {
    "skill_id": "email.process_inbox",
    "skill_name": "Process Email Inbox",
    "tier": 3,
    "total_steps": 3
  },
  "timestamp": "2026-02-24T10:30:00Z"
}

event: skill.step_completed
id: evt_01JMXYA
data: {
  "type": "skill.step_completed",
  "execution_id": "exec_123",
  "data": {
    "step_id": "fetch_emails",
    "step_index": 0,
    "result_summary": "Fetched 47 emails"
  },
  "timestamp": "2026-02-24T10:30:02Z"
}

event: agent.response
id: evt_01JMXYB
data: {
  "type": "agent.response",
  "session_id": "sess_abc",
  "data": {
    "output": "I've processed your inbox...",
    "signal": { "mode": "execute", "weight": 0.85, ... },
    "skills_used": ["email.process_inbox"],
    "iteration_count": 4,
    "execution_ms": 2340
  },
  "timestamp": "2026-02-24T10:30:05Z"
}
```

---

## 6. Authentication Model

### 6.1 Open-Source / Local Mode

Continues the existing HS256 JWT approach from `internal/integrations/osa/auth.go`, extended with additional claims:

```json
{
  "iss": "miosa-sdk",
  "sub": "<user_id>",
  "iat": 1740398400,
  "exp": 1740399300,
  "user_id": "<uuid>",
  "workspace_id": "<uuid>",
  "template_id": "BusinessOS",
  "sdk_version": "0.1.0"
}
```

Changes from today:
- `issuer` changes from `"BusinessOS"` to `"miosa-sdk"` (OSA validates this)
- Added `template_id` claim — identifies which OS Template is calling
- Added `sdk_version` for compatibility tracking
- Token TTL remains 15 minutes

**Configuration:**
```bash
# ~/.osa/config.json
{
  "sdk": {
    "shared_secret": "your-32-byte-secret",
    "allowed_issuers": ["miosa-sdk"]
  }
}
```

### 6.2 Cloud Mode (Premium)

```
Authentication flow:

1. Simple API key (all tiers):
   X-MIOSA-Key: mk_live_...
   X-Tenant-ID: ten_...

2. Enterprise OAuth2 (PKCE flow):
   - Identity provider: customer's SSO (Okta, Azure AD, etc.)
   - MIOSA acts as OAuth2 resource server
   - Short-lived bearer tokens (1hr), refresh via OAuth2 refresh flow
   - Scopes: osa:orchestrate, osa:skills:read, osa:skills:execute,
             osa:memory:read, osa:memory:write, osa:admin
```

### 6.3 Tenant Isolation

In cloud mode, every API request is scoped to a tenant:

```
Tenant isolation layers:
1. Network: Each tenant gets a dedicated OSA process (Elixir node)
2. Data: Workspace ID is enforced in every query
3. Memory: JSONL files are partitioned by tenant_id/user_id
4. Skills: Custom skills are tenant-scoped (private registry)
5. Events: PubSub topics include tenant_id prefix
```

---

## 7. Feature Matrix

### 7.1 Open-Source SDK Features

All features marked here are available to anyone running OSA locally.

| Feature | Details |
|---|---|
| Full ReAct agent loop | Max 30 iterations, tool use, context compaction |
| Signal classification | S=(M,G,T,F,W) 5-tuple on every message |
| Signal noise filter | Two-tier: deterministic (weight threshold) + LLM |
| Skills: built-in (5) | file_read, file_write, shell_execute, web_search, memory_save |
| Skills: custom SKILL.md | Drop `.md` files into `~/.osa/skills/`, hot-reloaded |
| Machines | Core/Communication/Productivity/Research toggle |
| JSONL memory | Session persistence, Cortex synthesis |
| Local SSE streaming | Real-time agent events over HTTP SSE |
| L1 autonomy | Reactive: responds to explicit requests only |
| L2 autonomy | Suggests next actions, no autonomous execution |
| HTTP API (new) | All SDK endpoints on localhost:8089 |
| JWT local auth | HS256 shared secret, 15min TTL |

**Autonomy Level Definitions:**

```
L1 — Reactive:    Responds only when called. Zero initiative.
L2 — Suggestive:  Responds to calls + surfaces suggestions.
L3 — Proactive:   Monitors state, initiates without being asked.   [PREMIUM]
L4 — Adaptive:    Learns user patterns, adjusts behavior.          [PREMIUM]
L5 — Autonomous:  Full operational independence within policies.   [PREMIUM]
```

### 7.2 MIOSA SDK Premium Additions

| Feature | Details | Autonomy Level |
|---|---|---|
| SORX skill engine | 4 reliability tiers (see below) | L1-L5 |
| SORX Tier 1 | Deterministic, 100% uptime, no AI | L1 |
| SORX Tier 2 | Structured AI (Haiku), 95-99% uptime | L2 |
| SORX Tier 3 | Reasoning AI (Sonnet), 80-95% uptime | L3 |
| SORX Tier 4 | Generative AI (Opus), variable uptime | L4-L5 |
| CARRIER bridge | AMQP Go-Elixir, Tier 3-4 only | L3-L5 |
| L3-L5 autonomy | Proactive monitor, pattern learning | L3-L5 |
| Cross-OS reasoning | One OSA reasoning across BOS + ContentOS | L3-L5 |
| Cloud instances | Managed OSA on MIOSA infrastructure | All |
| Multi-tenant isolation | Workspace isolation, separate OSA processes | All |
| Enterprise auth | OAuth2/OIDC, SSO integration | All |
| Audit log | Immutable log of all agent actions | All |
| Compliance export | SOC2/GDPR data export | All |
| Proactive monitoring rules | Custom pattern detection | L3-L5 |
| Temperature governance | Admin-enforced temperature ceiling | All |

**SORX Tier Summary:**

```
Tier 1 — Deterministic
  Reliability: 100% when API is up
  AI: None — pure code execution
  Examples: Gmail list, HubSpot sync, calendar read
  Latency: <100ms

Tier 2 — Structured AI
  Reliability: 95-99%
  AI: Haiku for parameter extraction or simple routing
  Examples: Email triage, task prioritization
  Latency: <500ms

Tier 3 — Reasoning AI
  Reliability: 80-95%
  AI: Sonnet for multi-step reasoning
  Examples: Process inbox with action extraction, client health
  Latency: 1-10s, may require human-in-the-loop

Tier 4 — Generative AI
  Reliability: Variable
  AI: Opus for novel/generative tasks
  Examples: New skill generation, complex analysis
  Latency: 5-60s
  Gate: Always requires warm+ temperature or explicit approval
```

---

## 8. Package Structure

### 8.1 Initial Development (Monorepo)

```
miosa-sdk/
├── spec/
│   └── openapi.yaml              # Single source of truth for all types
│
├── miosa-sdk-go/                 # Go SDK (replaces internal/integrations/osa/)
│   ├── go.mod                    # module github.com/miosa/sdk-go
│   ├── client.go                 # Client interface
│   ├── local_client.go           # HTTP/SSE implementation (local mode)
│   ├── cloud_client.go           # Cloud implementation (premium)
│   ├── carrier_client.go         # AMQP CARRIER (premium, Sprint 5)
│   ├── auth.go                   # JWT generation/validation
│   ├── resilience.go             # Circuit breaker, backoff, queue
│   ├── types.go                  # Generated from openapi.yaml
│   ├── streaming.go              # SSE client
│   └── README.md
│
├── miosa-sdk-js/                 # TypeScript/JS SDK
│   ├── package.json              # name: @miosa/sdk
│   ├── src/
│   │   ├── client.ts             # OSAClient interface
│   │   ├── local-client.ts       # HTTP/SSE implementation
│   │   ├── cloud-client.ts       # Cloud implementation (premium)
│   │   ├── streaming.ts          # SSE + AsyncGenerator
│   │   ├── svelte.ts             # Svelte store integration
│   │   ├── auth.ts               # JWT signing (Node.js), header injection
│   │   └── types.ts              # Generated from openapi.yaml
│   └── README.md
│
└── miosa-sdk-ex/                 # Elixir SDK (OSA-to-OSA)
    ├── mix.exs                   # {:miosa_sdk, "~> 0.1"}
    ├── lib/
    │   ├── miosa_sdk.ex          # Main module
    │   ├── client.ex             # HTTP/SSE Elixir client (Req + Mint)
    │   ├── carrier.ex            # AMQP client (premium)
    │   └── types.ex              # Generated structs from openapi.yaml
    └── README.md
```

### 8.2 OSA HTTP Channel (new file — to be created)

This is the new Elixir code that OSA needs to expose the SDK's API:

```
OptimalSystemAgent/
└── lib/optimal_system_agent/
    └── channels/
        ├── cli.ex                 # Existing
        └── http.ex                # NEW — Plug.Router for SDK
            ├── Plug.Router
            ├── POST /api/v1/orchestrate
            ├── GET  /api/v1/orchestrate/:session_id/stream (SSE)
            ├── POST /api/v1/classify
            ├── POST /api/v1/skills/:id/execute
            ├── GET  /api/v1/skills/:id/executions/:exec_id
            ├── GET  /api/v1/skills
            ├── POST /api/v1/memory
            ├── GET  /api/v1/memory/:key
            ├── GET  /api/v1/memory/search
            ├── GET  /api/v1/machines
            ├── PUT  /api/v1/machines
            └── GET  /health
```

### 8.3 BOS Backend Integration Point

After migrating to the SDK, BOS's import path changes:

```go
// Before (current)
import "github.com/your-org/bos/internal/integrations/osa"
client, _ := osa.NewResilientClient(config)
resp, _ := client.Orchestrate(ctx, req)

// After (SDK migration)
import osa "github.com/miosa/sdk-go"
client, _ := osa.NewLocalClient(osa.LocalConfig{
    BaseURL:      "http://localhost:8089",
    SharedSecret: os.Getenv("OSA_SHARED_SECRET"),
    Resilience:   osa.DefaultResilienceConfig(),
})
resp, _ := client.Orchestrate(ctx, osa.OrchestrateRequest{
    Input:       req.Input,
    UserID:      req.UserID.String(),
    WorkspaceID: req.WorkspaceID.String(),
})
```

The resilience behavior (circuit breaker, backoff, cache, queue) is preserved inside the SDK's `NewLocalClient` implementation.

---

## 9. OSA HTTP API Contract

This is the complete REST API that OSA must implement via the new `channels/http.ex` Plug adapter. This is what Sprint N (HTTP channel) must deliver.

### 9.1 Base URL and Versioning

```
Local:  http://localhost:8089/api/v1
Cloud:  https://api.miosa.ai/v1

All endpoints require:
  Authorization: Bearer <jwt>    (local)
  X-MIOSA-Key: mk_live_...       (cloud)
  Content-Type: application/json
  X-User-ID: <uuid>
  X-Workspace-ID: <uuid>         (optional)
  X-SDK-Version: 0.1.0
```

### 9.2 Agent Endpoints

#### POST /api/v1/orchestrate

Runs the full OSA ReAct loop. Synchronous — waits for final response.

**Request:**
```json
{
  "input": "Process my inbox and extract action items",
  "user_id": "550e8400-e29b-41d4-a716-446655440000",
  "workspace_id": "workspace_uuid",
  "session_id": "sess_abc123",
  "context": {
    "template": "BusinessOS",
    "current_view": "dashboard"
  },
  "machines": ["core", "communication"]
}
```

**Response 200:**
```json
{
  "session_id": "sess_abc123",
  "output": "I've processed your inbox...",
  "signal": {
    "mode": "execute",
    "genre": "direct",
    "type": "general",
    "format": "message",
    "weight": 0.85,
    "channel": "http",
    "timestamp": "2026-02-24T10:30:00Z"
  },
  "skills_used": ["email.process_inbox"],
  "iteration_count": 4,
  "execution_ms": 2340,
  "metadata": {}
}
```

**Response 422** (signal filtered as noise):
```json
{
  "error": "signal_filtered",
  "code": "SIGNAL_BELOW_THRESHOLD",
  "details": "Signal weight 0.35 below threshold 0.60",
  "signal": { "weight": 0.35, ... }
}
```

---

#### GET /api/v1/orchestrate/:session_id/stream

Server-Sent Events stream for a session. Long-lived HTTP connection.

**Headers:**
```
Accept: text/event-stream
Cache-Control: no-cache
```

**Stream events:**

| Event Type | When |
|---|---|
| `agent.thinking` | Each ReAct iteration begins |
| `agent.response` | Final response produced |
| `agent.error` | Unrecoverable error |
| `skill.started` | Skill execution begins |
| `skill.step_completed` | A skill step finishes |
| `skill.waiting_decision` | Human-in-the-loop pause |
| `skill.completed` | Skill execution succeeds |
| `skill.failed` | Skill execution fails |
| `signal.classified` | Signal 5-tuple produced |
| `signal.filtered` | Signal filtered as noise |

---

#### POST /api/v1/classify

Classifies a message without running the agent loop. Useful for routing decisions in OS Templates.

**Request:**
```json
{
  "message": "Schedule a meeting with John next Tuesday",
  "channel": "http",
  "user_id": "uuid"
}
```

**Response 200:**
```json
{
  "signal": {
    "mode": "execute",
    "genre": "direct",
    "type": "scheduling",
    "format": "message",
    "weight": 0.78,
    "channel": "http",
    "timestamp": "2026-02-24T10:30:00Z"
  }
}
```

---

### 9.3 Skill Endpoints

#### GET /api/v1/skills

List all available skills.

**Query params:** `?category=communication&tier=3`

**Response 200:**
```json
{
  "skills": [
    {
      "id": "email.process_inbox",
      "name": "Process Email Inbox",
      "description": "Scans inbox and extracts actionable items",
      "category": "communication",
      "tier": 3,
      "required_integrations": ["gmail"],
      "requires_approval_at": "warm",
      "success_rate": 0.92,
      "avg_execution_ms": 3200
    }
  ],
  "total": 12
}
```

---

#### POST /api/v1/skills/:skill_id/execute

Execute a skill. Async by default — returns execution ID for polling/streaming.

**Request:**
```json
{
  "user_id": "uuid",
  "params": {
    "max_results": 50,
    "label": "INBOX"
  },
  "temperature": "warm",
  "async": true
}
```

**Response 202 (async):**
```json
{
  "execution_id": "exec_550e8400",
  "skill_id": "email.process_inbox",
  "status": "pending",
  "progress": 0.0,
  "current_step": 0,
  "total_steps": 3,
  "started_at": "2026-02-24T10:30:00Z"
}
```

---

#### GET /api/v1/skills/:skill_id/executions/:execution_id

Poll execution status.

**Response 200:**
```json
{
  "execution_id": "exec_550e8400",
  "skill_id": "email.process_inbox",
  "status": "complete",
  "progress": 1.0,
  "current_step": 3,
  "total_steps": 3,
  "result": {
    "tasks_created": 7,
    "emails_processed": 47
  },
  "started_at": "2026-02-24T10:30:00Z",
  "completed_at": "2026-02-24T10:30:05Z"
}
```

---

### 9.4 Memory Endpoints

#### POST /api/v1/memory

Save a memory entry.

**Request:**
```json
{
  "user_id": "uuid",
  "key": "client:acme:last_contact",
  "value": "2026-02-20T14:30:00Z",
  "tags": ["client", "acme", "contact"],
  "ttl_seconds": 2592000
}
```

**Response 201:**
```json
{
  "id": "mem_abc",
  "key": "client:acme:last_contact",
  "created_at": "2026-02-24T10:30:00Z"
}
```

---

#### GET /api/v1/memory/:key

Retrieve a memory entry by key.

**Response 200 / 404**

---

#### GET /api/v1/memory/search

Semantic search over memory.

**Query params:** `?q=acme+client+contact&limit=10&tags=client`

**Response 200:**
```json
{
  "entries": [
    {
      "id": "mem_abc",
      "key": "client:acme:last_contact",
      "value": "2026-02-20T14:30:00Z",
      "relevance": 0.94,
      "tags": ["client", "acme"]
    }
  ],
  "total": 3
}
```

---

### 9.5 Configuration Endpoints

#### GET /api/v1/machines

List current machine configuration.

**Response 200:**
```json
{
  "active": ["core", "communication"],
  "available": [
    { "id": "core", "active": true, "description": "Always active. File, shell, web." },
    { "id": "communication", "active": true, "description": "Telegram, Discord, Slack." },
    { "id": "productivity", "active": false, "description": "Calendar, tasks." },
    { "id": "research", "active": false, "description": "Deep search, translation." }
  ]
}
```

---

#### PUT /api/v1/machines

Update machine configuration.

**Request:**
```json
{
  "machines": {
    "communication": true,
    "productivity": true,
    "research": false
  }
}
```

---

### 9.6 Health Endpoint

#### GET /health

No authentication required.

**Response 200:**
```json
{
  "status": "healthy",
  "version": "1.2.0",
  "uptime_seconds": 86400,
  "agents": {
    "loop": "running",
    "scheduler": "running",
    "compactor": "running",
    "cortex": "running"
  },
  "skills_loaded": 12,
  "machines_active": ["core", "communication"],
  "timestamp": "2026-02-24T10:30:00Z"
}
```

---

### 9.7 Error Handling

All errors follow a consistent format:

```json
{
  "error": "machine_readable_code",
  "code": "HUMAN_READABLE_CODE",
  "details": "Full description of what went wrong",
  "request_id": "req_abc123"
}
```

**HTTP Status Codes:**

| Status | Meaning |
|---|---|
| 200 | Success (sync operations) |
| 201 | Created (memory.save) |
| 202 | Accepted (async skill execution) |
| 400 | Bad request (invalid payload) |
| 401 | Unauthenticated (missing/invalid JWT) |
| 403 | Forbidden (valid JWT, insufficient claims) |
| 404 | Resource not found |
| 409 | Conflict (duplicate session_id) |
| 422 | Unprocessable (valid request, agent rejected — e.g., signal filtered) |
| 429 | Rate limited |
| 500 | Internal error |
| 503 | OSA unavailable (circuit breaker open) |

### 9.8 Rate Limiting

```
Local mode (no rate limiting by default):
  - Configurable via ~/.osa/config.json
  - "rate_limit": { "requests_per_minute": 60 }

Cloud mode (enforced):
  Free tier:         60 req/min, 5 concurrent SSE
  Pro:               600 req/min, 25 concurrent SSE
  Enterprise:        Custom limits
```

---

## 10. Migration Path

### 10.1 Phase 1 — OSA HTTP Channel (Next Sprint)

**What to build:**
1. `lib/optimal_system_agent/channels/http.ex` — Plug.Router implementing all `/api/v1/*` endpoints
2. Wire Bandit to serve on port 8089 in `application.ex`
3. JWT validation middleware reading from `~/.osa/config.json`
4. SSE endpoint bridging `Bridge.PubSub.subscribe_session/1` to HTTP stream

**What changes in BOS:** Nothing yet. Existing `internal/integrations/osa/` continues to work.

**Verification:** All existing BOS integration tests pass against the new HTTP channel.

---

### 10.2 Phase 2 — Go SDK (miosa-sdk-go v0.1.0)

**What to build:**
1. `miosa-sdk-go/` with the `Client` interface
2. `NewLocalClient` implementation wrapping HTTP + SSE
3. Migrate `ResilientClient` logic into SDK (circuit breaker, backoff, queue preserved)
4. Update BOS `internal/integrations/osa/` to be a thin wrapper calling the SDK

**Migration strategy (strangler fig):**

```
Sprint A: SDK exists alongside internal/integrations/osa/
Sprint B: New BOS features use SDK directly
Sprint C: Old code paths migrated to SDK
Sprint D: internal/integrations/osa/ deleted; SDK is the only path
```

**Backward compatibility guarantee:**
- All existing `OrchestrateRequest` / `OrchestrateResponse` types are preserved
- `GenerateApp` and `GenerateAppFromTemplate` become thin wrappers around `Orchestrate`
- Shared secret configuration is identical

---

### 10.3 Phase 3 — TypeScript SDK (miosa-sdk-js v0.1.0)

**What to build:**
1. `miosa-sdk-js/` TypeScript package
2. Svelte store integration for BOS frontend
3. Replace any direct `fetch` calls to OSA in the Svelte frontend with SDK

**BOS Frontend change:**
```typescript
// Before: raw fetch to backend-go which proxies to OSA
const response = await fetch('/api/osa/orchestrate', { ... })

// After: SDK client (frontend calls OSA directly via backend proxy,
// or directly if on same network — configurable)
import { createClient } from '@miosa/sdk'
const osa = createClient({ mode: 'local', baseUrl: '/api/osa-proxy', ... })
const response = await osa.orchestrate({ input: '...' })
```

---

### 10.4 Phase 4 — CARRIER Bridge (Sprint 5, Premium)

**What to build:**
1. RabbitMQ integration in OSA (`lib/optimal_system_agent/channels/carrier.ex`)
2. Go CARRIER client in `miosa-sdk-go/carrier_client.go`
3. SORX engine integration: Tier 3-4 skills routed through CARRIER instead of HTTP

**No changes to open-source SDK.** CARRIER is activated only when `NewCloudClient` or `NewCarrierClient` is used.

---

### 10.5 Phase 5 — Premium Feature Gating

After CARRIER is live, premium features are activated by license key:

```go
client, _ := osa.NewCloudClient(osa.CloudConfig{
    APIKey:     os.Getenv("MIOSA_API_KEY"),
    TenantID:   os.Getenv("MIOSA_TENANT_ID"),
    AutonomyLevel: osa.AutonomyL3Proactive,
})
// SORX Tier 3-4, CARRIER, cross-OS reasoning all enabled automatically
```

---

## 11. Dependency Diagram

```
                        ┌───────────────────────────────┐
                        │       spec/openapi.yaml        │
                        │  (single source of truth for  │
                        │   all API types + contracts)  │
                        └──────────────┬────────────────┘
                                       │ codegen
                    ┌──────────────────┼──────────────────┐
                    ↓                  ↓                   ↓
           miosa-sdk-go          miosa-sdk-js         miosa-sdk-ex
           (Go module)           (@miosa/sdk)         (hex package)
                    │                  │                   │
                    └──────────────────┴───────────────────┘
                                       │
                              SDK Transport Layer
                    ┌──────────────────┼──────────────────┐
                    ↓                  ↓                   ↓
            Local HTTP           Cloud HTTPS          CARRIER AMQP
          localhost:8089        api.miosa.ai        RabbitMQ [PREMIUM]
                    │                  │
                    └──────────────────┘
                                       │
                        ┌──────────────────────────┐
                        │   OSA (Elixir/OTP)        │
                        │                          │
                        │  channels/http.ex  ←NEW  │
                        │  channels/cli.ex          │
                        │  channels/carrier.ex ←NEW │
                        │                          │
                        │  agent/loop.ex            │
                        │  signal/classifier.ex     │
                        │  skills/registry.ex       │
                        │  machines.ex              │
                        │  bridge/pubsub.ex         │
                        │  intelligence/*.ex        │
                        └──────────────────────────┘

OS Templates (consumers of SDK):
  BusinessOS   →  miosa-sdk-go (backend) + miosa-sdk-js (frontend)
  ContentOS    →  miosa-sdk-go (backend) + miosa-sdk-js (frontend)
  Custom       →  any SDK via documented API contract
```

---

## Appendix A: Naming Conventions

| Concept | Open-Source Name | MIOSA Premium Name |
|---|---|---|
| Skill engine | Skills.Registry | SORX Engine |
| Skills | Skills | SORX Skills |
| HTTP bridge | OSA HTTP Channel | MIOSA Gateway |
| Go-Elixir bridge | (not available) | CARRIER |
| Proactive monitoring | (not available) | MIOSA Watch |
| Cloud instances | (not available) | MIOSA Cloud |

---

## Appendix B: OpenAPI Spec Stub

The full OpenAPI spec lives at `spec/openapi.yaml`. Key metadata:

```yaml
openapi: 3.1.0
info:
  title: OptimalSystemAgent API
  version: 0.1.0
  description: |
    The OSA API is consumed by MIOSA SDK clients.
    Open-source edition: localhost:8089
    Premium edition: api.miosa.ai

servers:
  - url: http://localhost:8089/api/v1
    description: Local OSA instance (open-source)
  - url: https://api.miosa.ai/v1
    description: MIOSA Cloud (premium)

components:
  securitySchemes:
    localJWT:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: HS256 JWT signed with shared secret
    miosaAPIKey:
      type: apiKey
      in: header
      name: X-MIOSA-Key
      description: MIOSA Cloud API key (premium)

security:
  - localJWT: []
```

---

*Document produced by the MIOSA Architect agent.*
*Review required from: @backend-go (implementation), @devops-engineer (infra), @security-auditor (auth model).*
*Next revision triggers: Sprint 5 CARRIER design, OSA HTTP channel implementation.*
