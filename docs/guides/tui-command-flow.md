# TUI Command Flow Map

> Decision tree for every command: input → state transitions → async results → view rendering

## Flow Legend

```
[State]     = TUI state (Idle, Processing, ModelPicker, etc.)
{async}     = Background tea.Cmd (HTTP call)
<msg>       = Message returned to Update()
→           = Synchronous transition
⟶           = Asynchronous (via tea.Cmd)
✓           = Terminal (stays in current state)
⚠           = Known issue
```

---

## State Machine Overview

```
                    ┌──────────────┐
        start ───► │ Connecting   │
                    └──────┬───────┘
                           │ health OK
                    ┌──────▼───────┐
                    │   Banner     │──── 2s timeout or keypress
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐◄─── all commands return here
          ┌────────│    Idle       │────────┐
          │        └──┬────┬───┬──┘        │
          │           │    │   │            │
     /models     text │  Ctrl+K  plan response
          │           │    │   │            │
  ┌───────▼──┐  ┌─────▼──┐ ┌──▼─────┐ ┌───▼────────┐
  │ Model    │  │Process-│ │Palette │ │Plan Review  │
  │ Picker   │  │  ing   │ │        │ │             │
  └──────────┘  └────────┘ └────────┘ └─────────────┘
```

---

## Command Flow Details

### `/help`
```
[Idle] → submitInput("/help")
  → m.chat.AddSystemMessage(dynamicHelpText())
  → return nil (stays Idle)
  → View: chat shows help text ✓
```
**No issues.** Synchronous, no state change.

---

### `/clear`
```
[Idle] → submitInput("/clear")
  → m.chat = NewChat() (reset)
  → m.chat.SetWelcomeData(...)
  → return nil (stays Idle)
  → View: welcome screen ✓
```
**No issues.** Synchronous.

---

### `/exit`, `/quit`
```
[Idle] → submitInput("/exit")
  → m.closeSSE()
  → return tea.Quit
```
**No issues.**

---

### `/models`
```
[Idle] → submitInput("/models")
  → m.chat.AddUserMessage("/models")          ← user sees their input in chat
  → return fetchModels()                       ← async HTTP call
  → state stays [Idle]                         ⚠ PROBLEM 1

{async} GET /api/v1/models
  ⟶ <msg.ModelListResult>

[Idle] → handleModelList(r)
  → if error: chat.AddSystemError → stays Idle ✓
  → if empty: chat.AddSystemWarning → stays Idle ✓
  → sort items, picker.SetItems(), picker.SetWidth()
  → m.state = StateModelPicker
  → m.input.Blur()
  → return nil
  → View: shows picker overlay ✓

[ModelPicker] → handlePickerKey(k)
  → ↑/↓: navigate picker
  → Enter: picker emits PickerChoice
  → Esc/Ctrl+C: picker emits PickerCancel

<PickerChoice> → handlePickerChoice(c)
  → picker.Clear()
  → state = Idle
  → chat.AddSystemMessage("Switching to ...")
  → return switchModel() ← async HTTP call
  → input.Focus()

{async} POST /api/v1/models/switch
  ⟶ <msg.ModelSwitchResult>

[Idle] → handleModelSwitch(r)
  → if error: chat.AddSystemError ✓
  → status.SetProviderInfo(), banner.SetModelOverride()
  → chat.AddSystemMessage("Switched to ...")
  → return checkHealth() ← re-verify

<PickerCancel>
  → picker.Clear()
  → state = Idle
  → return input.Focus() ✓
```

**PROBLEM 1 — FIXED:** Between `fetchModels()` dispatch and the `ModelListResult` arriving, the state was still `Idle`. User could type another command during this gap.

**FIX APPLIED:** `m.input.Blur()` + toast "Loading models..." immediately on `/models` dispatch. Input re-focused on error/empty result or when picker opens. Toast auto-dismisses.

---

### `/model` (no args)
```
[Idle] → submitInput("/model")
  → chat.AddSystemMessage("Current: provider / model")
  → return nil ✓
```
**No issues.** Synchronous.

---

### `/model <provider>/<name>` (direct switch)
```
[Idle] → submitInput("/model anthropic/claude-3")
  → chat.AddUserMessage(...)
  → return switchModel("anthropic", "claude-3") ← async
  → state stays [Idle]                          ⚠ PROBLEM 2

{async} POST /api/v1/models/switch
  ⟶ <msg.ModelSwitchResult>

[Idle] → handleModelSwitch(r)
  → update status + banner
  → chat.AddSystemMessage("Switched to ...")
  → return checkHealth()
```

**PROBLEM 2 — FIXED:** No loading indicator. User typed `/model anthropic/claude-3`, nothing happened visually for potentially seconds.

**FIX APPLIED:** `m.chat.AddSystemMessage("Switching to anthropic / claude-3...")` immediately before the async `switchModel()` call. Same for Ollama shorthand.

---

### `/model <name>` (Ollama shorthand)
```
Same as above with provider="ollama". Same PROBLEM 2.
```

---

### `/theme`
```
[Idle] → submitInput("/theme")
  → builds theme list string
  → chat.AddSystemMessage(list)
  → return nil ✓
```
**No issues.**

---

### `/theme <name>`
```
[Idle] → submitInput("/theme catppuccin")
  → style.SetTheme(name)
  → if fails: chat.AddSystemError ✓
  → if OK: config.Save(), chat.SetSize(), toast "Theme set to..."
  → return tickCmd() ✓
```
**No issues.**

---

### `/sessions`
```
[Idle] → submitInput("/sessions")
  → chat.AddUserMessage(...)
  → toast "Loading sessions..."
  → return Batch(listSessions(), tickCmd()) ← async

{async} GET /api/v1/sessions
  ⟶ <msg.SessionListResult>

[Idle] → handleSessionList(r)
  → chat.AddSystemMessage(formatted list) ✓
  → toast auto-dismisses ✓
```
**No issues.** Toast provides feedback during async call.

---

### `/session` (no args)
```
[Idle] → submitInput("/session")
  → chat.AddSystemMessage("Current session: abc12345") ✓
```
**No issues.**

---

### `/session new`
```
[Idle] → submitInput("/session new")
  → toast "Creating session..."
  → return Batch(createSession(), tickCmd()) ← async

{async} POST /api/v1/sessions
  ⟶ <msg.SessionSwitchResult>

[Idle] → handleSessionSwitch(r)
  → closeSSE(), reset chat
  → if messages: replay history
  → startSSE() ✓
```
**No issues.** Toast provides feedback during creation.

---

### `/session <id>`
```
[Idle] → submitInput("/session abc123")
  → toast "Switching to session abc123..."
  → return Batch(switchSession("abc123"), tickCmd()) ← async

{async} GET /api/v1/sessions/abc123 + GET /sessions/abc123/messages
  ⟶ <msg.SessionSwitchResult>

[Idle] → handleSessionSwitch(r)
  → closeSSE(), reset chat
  → replay messages
  → startSSE() ✓
```
**No issues.** Toast provides feedback during switch.

---

### `/login <user_id>`
```
[Idle] → submitInput("/login myuser")
  → toast "Authenticating..."
  → return Batch(doLogin("myuser"), tickCmd()) ← async

{async} POST /api/v1/auth/login
  ⟶ <msg.LoginResult>

[Idle] → Update case msg.LoginResult
  → if error: chat.AddSystemError
  → if OK: chat.AddSystemMessage("Authenticated"), restart SSE ✓
```
**No issues.** Toast provides feedback during auth.

---

### `/logout`
```
[Idle] → submitInput("/logout")
  → toast "Logging out..."
  → return Batch(doLogout(), tickCmd()) ← async

{async} POST /api/v1/auth/logout
  ⟶ <msg.LogoutResult>

[Idle] → case msg.LogoutResult
  → chat.AddSystemMessage("Logged out"), closeSSE() ✓
```
**No issues.** Toast provides feedback during logout.

---

### `/bg`
```
[Idle] → submitInput("/bg")
  → if empty: "No background tasks running."
  → else: formatted list
  → return nil ✓
```
**No issues.**

---

### `Ctrl+K` (Command Palette)
```
[Idle] → handleIdleKey → key.Matches(k, m.keys.Palette)
  → openPalette()
  → build items from localCmds + commandEntries
  → state = StatePalette
  → input.Blur()
  → palette.Open(items, width, height) ← returns init cmd

[Palette] → handlePaletteKey(k)
  → palette.Update(k)
  → type to filter, ↑/↓ navigate

  → Enter: <PaletteExecuteMsg{Command: "/models"}>
    → state = Idle
    → m.submitInput(command)                    ← re-enters full flow
    → ✓ correct

  → Esc: <PaletteDismissMsg>
    → state = Idle
    → input.Focus() ✓
```
**No issues.** Palette correctly re-enters submitInput.

---

### Any `/command` (backend passthrough)
```
[Idle] → submitInput("/status")
  → not matched by local cases
  → falls through to: executeCommand("status", "")
  → state stays [Idle]                         ⚠ PROBLEM 3

{async} POST /api/v1/commands/execute
  ⟶ <msg.CommandResult>

[Idle] → handleCommand(r)
  → switch r.Kind:
    "text"   → chat.AddSystemMessage(output) ✓
    "error"  → chat.AddSystemError(output) ✓
    "prompt" → submitPrompt(output) → state = Processing ✓
    "action" → handleCommandAction(action, output)
      → ":new_session" → reset chat + SSE ✓
      → ":exit"        → tea.Quit ✓
      → ":clear"       → reset chat ✓
      → "{:resume_session, ...}" → switch session ✓
      → default        → show output ✓
```

**PROBLEM 3 — FIXED:** Between `executeCommand()` dispatch and `CommandResult` arriving, the state was `Idle` with no loading indicator.

**FIX APPLIED:** Toast "Running /<cmd>..." shown immediately on dispatch. Auto-dismisses when result arrives. For "prompt" kind commands, the transition from `handleCommand` → `submitPrompt` → `StateProcessing` still has a brief flash, but the toast provides feedback during the wait.

---

### Free text (non-command)
```
[Idle] → submitInput("explain Signal Theory")
  → not a /command
  → activity.Reset(), activity.Start()
  → agents.Reset(), tasks.Reset()
  → streamBuf.Reset()
  → state = StateProcessing
  → processingStart = Now()
  → status.SetActive(true)
  → chat.SetProcessingView(activity.View())
  → input.Blur()
  → return Batch(orchestrate(text), tickCmd())

{async} POST /api/v1/orchestrate
  ⟶ <msg.OrchestrateResult>

[Processing] → handleOrchestrate(r)
  → activity.Stop(), chat.ClearProcessingView()
  → state = Idle, input.Focus()
  → chat.AddAgentMessage(output, signal, ms, model)
  → status.SetSignal(signal) ✓
```

**SSE events during Processing:**
```
StreamingTokenEvent → streamBuf.WriteString → chat.SetStreamingContent (live)
LLMRequestEvent    → activity.Update (iteration count)
ToolCallStartEvent → activity.Update (tool name)
ToolCallEndEvent   → activity.Update (duration, success)
ToolResultEvent    → activity.Update + chat preview
LLMResponseEvent   → status.SetStats (tokens)
ContextPressure    → status.SetContext (utilization)
AgentResponseEvent → handleClientAgentResponse → state=Idle + render
```

**PROBLEM 4:** Dual response path. Both `OrchestrateResult` (from HTTP POST) and `AgentResponseEvent` (from SSE) can render the final response. The `responseReceived` flag prevents duplicates, but the race means:
- If SSE `agent_response` arrives first → renders from SSE, HTTP result silently dropped ✓
- If HTTP result arrives first → renders from HTTP, SSE `agent_response` silently dropped ✓
- But if the content differs slightly (e.g., SSE has signal, HTTP doesn't) → user gets whichever arrives first.

This is handled correctly by `responseReceived` and `cancelled` flags.

---

### Plan detection (during Processing)
```
[Processing] ← client.AgentResponseEvent (from SSE)
  → handleClientAgentResponse(r)
  → if response contains "## Plan" or "# Plan":
    → plan.SetPlan(response)
    → state = StatePlanReview
    → return nil (no input focus — plan has its own keys)

[PlanReview] → handlePlanKey(k)
  → plan.Update(k)
  → 'a' → PlanDecision{approve}
  → 'r' → PlanDecision{reject}
  → 'e' → PlanDecision{edit}

<PlanDecision> → handlePlanDecision(d)
  → plan.Clear()
  → approve: state=Processing, orchestrate("Approved. Execute the plan.")
  → reject:  state=Idle, input.Focus()
  → edit:    state=Idle, input.Focus(), input.SetValue("Regarding the plan: ")
```
**No issues.** Clean flow.

---

## Summary of Issues

| # | Problem | Severity | Status |
|---|---------|----------|--------|
| P1 | **No loading state during async command dispatch** — input blur + toast on `/models` dispatch. | MAJOR | **FIXED** |
| P2 | **No "Switching..." feedback for `/model <name>`** — system message before async call. | MINOR | **FIXED** |
| P3 | **Backend commands have no loading indicator** — toast "Running /cmd..." on dispatch. | MAJOR | **FIXED** |
| P4 | Dual response path (HTTP + SSE) — handled correctly by flags, not a bug. | — | OK |

---

## Recommended Fixes

### Fix P1 + P3: Loading state for async commands — IMPLEMENTED

**Approach chosen: Toast notifications (Option B)**

- `/models` → `m.toasts.Add("Loading models...", model.ToastInfo)` + `m.input.Blur()` + re-focus on error/empty
- `/model <provider>` → `m.toasts.Add("Loading <provider> models...", model.ToastInfo)` + `m.input.Blur()`
- `/sessions` → `m.toasts.Add("Loading sessions...", model.ToastInfo)`
- All backend passthrough → `m.toasts.Add("Running /<cmd>...", model.ToastInfo)`

### Fix P2: Feedback for `/model <name>` — IMPLEMENTED

```go
// "/model provider/name" → system message before async call
m.chat.AddSystemMessage(fmt.Sprintf("Switching to %s / %s...", parts[0], parts[1]))
return m, m.switchModel(parts[0], parts[1])

// "/model qwen3:8b" → same for ollama shorthand
m.chat.AddSystemMessage(fmt.Sprintf("Switching to ollama / %s...", arg))
return m, m.switchModel("ollama", arg)
```

### Input guard during async waits — IMPLEMENTED

`m.input.Blur()` called in `/models` dispatch. `m.input.Focus()` restored in `handleModelList` error/empty paths and when picker opens (already handled by `handlePickerChoice`/`PickerCancel`).
