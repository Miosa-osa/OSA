# Troubleshooting Common Issues

Audience: developers and operators resolving runtime problems in OSA.

---

## "Provider not configured"

**Symptom:** OSA starts but immediately shows an error like
`Provider not configured` or `No LLM provider available`.

**Cause:** No API key is set for any provider, and Ollama is not reachable on
`OLLAMA_URL`.

**Resolution:**

1. Check what provider was auto-detected:

   ```elixir
   Application.get_env(:optimal_system_agent, :default_provider)
   ```

2. Check that the API key for that provider is set:

   ```sh
   echo $ANTHROPIC_API_KEY
   echo $OPENAI_API_KEY
   echo $GROQ_API_KEY
   ```

3. If using Ollama, check it is running:

   ```sh
   curl http://localhost:11434/api/tags
   ```

4. Set the key and restart:

   ```sh
   export ANTHROPIC_API_KEY=sk-ant-...
   bin/osa
   ```

5. Alternatively, run `bin/osa setup` to configure interactively.

---

## "Tools not executing"

**Symptom:** The LLM produces tool call JSON but no tool runs, or the loop
returns without executing tools.

**Causes and resolutions:**

**A. Permission tier blocks the tool.**
The session's `permission_tier` may be `:read_only`, which blocks write tools.

```elixir
# Check the tier
[{pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)
:sys.get_state(pid) |> Map.get(:permission_tier)
```

Adjust the tier by setting `OSA_PERMISSION_TIER=full` or sending a
`/permissions` command.

**B. A hook is blocking the tool call.**

```elixir
OptimalSystemAgent.Agent.Hooks.metrics()
# Look for high block_count on :pre_tool_use
```

The `spend_guard` hook blocks all tool calls when the budget is exceeded. The
`security_check` hook blocks specific shell commands. Inspect the hook that is
blocking and determine whether the block is correct or a misconfiguration.

**C. The provider does not support function calling.**

Not all providers expose the `tool_capable_prefixes` required for function
calling. Check whether the active model supports tools:

```elixir
Application.get_env(:optimal_system_agent, :default_provider)
```

Providers with full tool support: Anthropic, OpenAI, Groq, Google, Mistral.
Some Ollama models support tools; many do not. Try a different model.

**D. Signal weight below tool threshold.**

Messages with signal weight below 0.20 receive a plain chat response (no
tools). This is intentional for low-information inputs like "ok" or "lol". If
it is triggering incorrectly, check the signal classifier output for the
message.

---

## "High latency"

**Symptom:** Responses take more than 30 seconds.

**Resolution:**

1. Check provider health:

   ```elixir
   MiosaLLM.HealthChecker.status()
   ```

   If a provider is in `:open` or `:rate_limited` state, OSA is using the
   fallback chain. The fallback chain may include slower providers.

2. Check whether tool execution is the bottleneck. Look at the EventStream for
   a session and measure the gap between `tool_call` and `tool_result` events.

3. Check whether context compaction is running (logged as `[Compactor]`).
   Compaction requires additional LLM calls and can add 5–30 seconds.

4. If using Ollama, check model load time:

   ```sh
   curl -X POST http://localhost:11434/api/generate \
     -d '{"model":"qwen2.5:7b","prompt":"hi","stream":false}'
   ```

---

## "Session not found"

**Symptom:** HTTP API returns 404 or `session_not_found` for a known
session ID.

**Cause:** The session's `Agent.Loop` process has terminated. Sessions are
in-memory; they do not survive application restarts.

**Resolution:**

1. Check whether the session still exists:

   ```elixir
   Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id)
   # [] means the session is gone
   ```

2. If the session crashed, inspect the supervisor log for a restart event.

3. Resume a previous session (if memory was persisted) via the CLI:

   ```
   /resume SESSION_ID
   ```

4. Create a new session if the old one cannot be recovered.

---

## "Port already in use"

**Symptom:** OSA fails to start with `{:error, :eaddrinuse}` or
`Address already in use` on port 9089.

**Resolution:**

1. Find the process using port 9089:

   ```sh
   # macOS / Linux
   lsof -i :9089

   # Or
   ss -tlnp | grep 9089
   ```

2. Kill the conflicting process:

   ```sh
   kill -9 <PID>
   ```

3. Or start OSA on a different port:

   ```sh
   OSA_HTTP_PORT=9000 bin/osa
   ```

---

## "Budget exceeded — spend_guard blocked"

**Symptom:** All tool calls are blocked with `"Budget exceeded"` in the logs.

**Cause:** The `spend_guard` hook is blocking tool calls because the daily or
per-call budget has been reached.

**Resolution:**

1. Check current budget status:

   ```elixir
   MiosaBudget.Budget.status()
   ```

2. Increase the limit temporarily:

   ```sh
   OSA_DAILY_BUDGET_USD=100.0 bin/osa
   ```

3. Or reset the budget counter in IEx (development only):

   ```elixir
   MiosaBudget.Budget.reset()
   ```

---

## "DLQ is growing"

**Symptom:** `OptimalSystemAgent.Events.DLQ.size()` keeps increasing. An
`:algedonic_alert` event is emitted.

**Cause:** An event handler is repeatedly crashing. After 3 retries the event
is dropped and an alert is fired.

**Resolution:**

1. Inspect the DLQ entries to find the failing handler and error:

   ```elixir
   OptimalSystemAgent.Events.DLQ.list()
   ```

2. Fix the handler (the module referenced in the entry's `:handler` field).

3. Flush the DLQ after fixing:

   ```elixir
   OptimalSystemAgent.Events.DLQ.flush()
   ```

---

## "Database connection error"

**Symptom:** `(DBConnection.ConnectionError)` or
`Postgrex.Error: connection refused` in logs.

**Cause:** SQLite database file is missing or locked (for the local store), or
`DATABASE_URL` is unreachable (for the platform PostgreSQL store).

**Resolution:**

For SQLite:

```sh
# Recreate the database
mix ecto.reset
```

For PostgreSQL (platform mode):

```sh
echo $DATABASE_URL
# Verify the URL is correct and the database is reachable
psql "$DATABASE_URL" -c "SELECT 1"
```

---

## "Compaction is not reducing context size"

**Symptom:** Token usage stays high after compaction runs.

**Cause:** The compactor's LLM calls may be disabled in test/dev, or the
context is genuinely large.

**Resolution:**

1. Check compaction is enabled:

   ```elixir
   Application.get_env(:optimal_system_agent, :compactor_llm_enabled, true)
   ```

2. Check compaction stats:

   ```elixir
   OptimalSystemAgent.Agent.Compactor.stats()
   ```

3. Force compaction on a session:

   ```elixir
   # From within IEx with the loop PID
   OptimalSystemAgent.Agent.Compactor.compact_now(session_id)
   ```

---

## Related

- [Debugging Core](./debugging-core.md) — inspect ETS, processes, and registries
- [Tracing Execution](./tracing-execution.md) — follow a message through the pipeline
- [Monitoring](../../operations/monitoring.md) — health checks and telemetry
