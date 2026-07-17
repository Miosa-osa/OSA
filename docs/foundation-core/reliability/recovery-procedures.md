# Recovery Procedures

Runbooks for recovering from specific failure conditions. Each procedure starts
with symptoms, explains what went wrong, and provides step-by-step recovery.

---

## Corrupted SQLite Database

**Affected component:** `OptimalSystemAgent.Store.Repo` (Ecto/SQLite3)

**Symptoms:**
- `[SQLiteBridge] Failed to persist message:` errors in logs
- `Exqlite.Error: database disk image is malformed` or `SQLITE_CORRUPT` errors
- Sessions fail to load message history
- `mix ecto.migrate` fails with corruption errors

**Root cause:** SQLite database file is corrupted. Common causes: unclean shutdown
during a write, disk full condition, or filesystem error.

**Recovery:**

1. Stop OSA:
   ```bash
   # If running as a release:
   bin/osagent stop
   # Or kill the Mix process if running in development
   ```

2. Locate the database file:
   ```bash
   # Default path (check config/config.exs for custom paths):
   ls -la priv/repo/osa.db
   ls -la ~/.osa/data/osa.db
   ```

3. Attempt SQLite repair:
   ```bash
   sqlite3 priv/repo/osa.db ".recover" | sqlite3 priv/repo/osa_recovered.db
   # Check if recovery succeeded:
   sqlite3 priv/repo/osa_recovered.db "SELECT count(*) FROM messages;"
   ```

4. If recovery succeeds, replace the corrupted file:
   ```bash
   cp priv/repo/osa.db priv/repo/osa.db.corrupted.$(date +%s)
   mv priv/repo/osa_recovered.db priv/repo/osa.db
   ```

5. If recovery fails, start from a clean database:
   ```bash
   cp priv/repo/osa.db priv/repo/osa.db.corrupted.$(date +%s)
   rm priv/repo/osa.db
   mix ecto.setup
   ```
   Session message history will be lost. Long-term memory in JSONL files (`~/.osa/memory/`)
   is stored separately and is not affected.

6. Restart OSA and verify:
   ```bash
   mix run --no-halt
   # Or for release:
   bin/osagent start
   ```

7. Verify the database:
   ```elixir
   # In IEx or via mix eval:
   OptimalSystemAgent.Store.Repo.query!("SELECT count(*) FROM messages")
   ```

**Prevention:** Ensure the OSA process receives a SIGTERM (not SIGKILL) on shutdown
so Ecto can close connections cleanly. Avoid storing OSA data on network filesystems.

---

## Stuck GenServer Processes

**Affected components:** Any GenServer — `Agent.Memory`, `Agent.Hooks`, `Tools.Registry`,
`Events.Bus`, `Providers.Registry`, `MiosaLLM.HealthChecker`, etc.

**Symptoms:**
- Requests time out with `{:EXIT, pid, :timeout}` or `GenServer.call` hanging
- Log line: `Process mailbox growing` or similar in `:observer`
- `Agent.Loop` stuck waiting for a tool result or memory write
- A specific GenServer's mailbox grows unboundedly (visible in `:observer`)

**Diagnosis:**

```elixir
# In IEx (iex -S mix or attach to running node):

# List all processes and find stuck ones:
Process.list()
|> Enum.filter(fn pid ->
  info = Process.info(pid, [:message_queue_len, :registered_name])
  info[:message_queue_len] > 100
end)
|> Enum.map(&Process.info(&1, [:registered_name, :message_queue_len, :current_function]))

# Get info on a specific registered process:
Process.info(Process.whereis(OptimalSystemAgent.Agent.Memory), [:message_queue_len, :current_function, :status])

# Check if a GenServer responds:
GenServer.call(OptimalSystemAgent.Agent.Memory, :ping, 2_000)
```

**Recovery — Option A: Kill and let supervisor restart**

For most GenServers under `:one_for_one` supervisors, the safest recovery is to
kill the stuck process. The supervisor restarts it automatically:

```elixir
# Find and kill a stuck GenServer:
pid = Process.whereis(OptimalSystemAgent.Agent.Memory)
Process.exit(pid, :kill)

# Verify it restarted:
Process.whereis(OptimalSystemAgent.Agent.Memory) != pid
```

Wait 1–2 seconds for the supervisor to restart the process. Verify the new PID differs
from the killed one.

**Recovery — Option B: Kill stuck Agent.Loop session**

A stuck session Loop (which is `:temporary` and will not be restarted) can be killed
to free resources and unblock the user:

```elixir
# List all sessions:
Registry.select(OptimalSystemAgent.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])

# Cancel a session's loop (signals the loop's cancel flag in ETS):
OptimalSystemAgent.Agent.Loop.cancel("session_id_here")

# If cancel doesn't work, kill the process:
case Registry.lookup(OptimalSystemAgent.SessionRegistry, "session_id_here") do
  [{pid, _}] -> Process.exit(pid, :kill)
  [] -> :not_found
end
```

**Recovery — Option C: Restart entire subsystem**

If multiple GenServers in a subsystem are stuck, restart the subsystem supervisor:

```elixir
# Restart AgentServices subsystem (all agent services):
Supervisor.terminate_child(OptimalSystemAgent.Supervisor, OptimalSystemAgent.Supervisors.AgentServices)
Supervisor.restart_child(OptimalSystemAgent.Supervisor, OptimalSystemAgent.Supervisors.AgentServices)
```

Note: This approach is destructive — all sessions and agent state will be reset.
Use it only if individual process kills are insufficient.

---

## Memory Leaks

**Affected components:** `Agent.Loop` processes, `Events.Bus` task pool, ETS tables.

**Symptoms:**
- BEAM memory grows over hours without recovery
- `:observer` shows increasing memory in a specific process or ETS table
- `Process.info(pid, :memory)` returns values over 100 MB for a single process
- `:osa_event_handlers` ETS table grows unboundedly

**Diagnosis:**

```elixir
# Top memory consumers:
Process.list()
|> Enum.map(fn pid ->
  {pid, Process.info(pid, [:memory, :registered_name, :message_queue_len])}
end)
|> Enum.sort_by(fn {_, info} -> info[:memory] || 0 end, :desc)
|> Enum.take(10)

# ETS table sizes:
:ets.all()
|> Enum.map(fn t -> {t, :ets.info(t, :size), :ets.info(t, :memory)} end)
|> Enum.sort_by(fn {_, _, mem} -> mem end, :desc)
|> Enum.take(10)
```

**Recovery — Long-running sessions leaking context**

Agent.Loop processes grow their `:messages` list over the course of a session. The
`Agent.Compactor` runs every 10 turns (configurable) to compress old context into a
summary. If compaction is not occurring:

```elixir
# Force compaction on a session:
OptimalSystemAgent.Agent.Compactor.compact_session("session_id_here")

# Or restart the session (user will lose conversation history in memory):
OptimalSystemAgent.Agent.Loop.cancel("session_id_here")
```

**Recovery — ETS table leaks**

If `:osa_event_handlers` grows unboundedly, orphaned handlers may not be deregistered:

```elixir
# Inspect handlers registered for a type:
:ets.lookup(:osa_event_handlers, :user_message)

# Clear all handlers for a type (use with caution):
:ets.delete(:osa_event_handlers, :user_message)

# Restart Events.Bus to recompile the router:
pid = Process.whereis(OptimalSystemAgent.Events.Bus)
Process.exit(pid, :kill)
```

**Recovery — General BEAM memory pressure**

```elixir
# Trigger garbage collection on all processes:
Process.list() |> Enum.each(&:erlang.garbage_collect/1)

# Check current BEAM memory:
:erlang.memory()
```

---

## Provider API Outages

**Affected component:** `Providers.Registry`, `MiosaLLM.HealthChecker`

**Symptoms:**
- All responses from one provider return errors
- Log: `[HealthChecker] anthropic: circuit OPENED after 3 consecutive failures`
- Users on sessions using that provider receive error messages

**Diagnosis:**

```elixir
# Check circuit breaker state for all providers:
MiosaLLM.HealthChecker.state()

# Check if a specific provider is available:
MiosaLLM.HealthChecker.is_available?(:anthropic)

# Test a provider directly:
OptimalSystemAgent.Providers.Registry.chat(
  [%{role: "user", content: "ping"}],
  provider: :anthropic,
  max_tokens: 5
)
```

**Recovery — Temporary outage (provider circuit is open)**

The circuit automatically transitions to `:half_open` after 30 seconds. No manual
intervention is needed if the provider recovers on its own.

To manually reset the circuit:

```elixir
# Force a success record to close the circuit:
MiosaLLM.HealthChecker.record_success(:anthropic)
```

**Recovery — Configure a different default provider**

If a provider is experiencing a prolonged outage:

```bash
# Set a different default provider via environment variable:
export OSA_DEFAULT_PROVIDER=groq
export GROQ_API_KEY=your_key_here

# Or via the /model command at runtime:
# /model groq llama-3.3-70b-versatile
```

**Recovery — Hot-swap provider for a specific session**

```elixir
# Override provider for a session via ETS (no restart needed):
:ets.insert(:osa_session_provider_overrides, {"session_id", :groq, "llama-3.3-70b-versatile"})
```

Or via the HTTP API:
```bash
curl -X POST http://localhost:9089/sessions/{id}/provider \
  -H "Content-Type: application/json" \
  -d '{"provider": "groq", "model": "llama-3.3-70b-versatile"}'
```

**Recovery — Update fallback chain at runtime**

```elixir
# Update the fallback chain without restart:
Application.put_env(:optimal_system_agent, :fallback_chain, [:groq, :openai, :ollama])
```

This takes effect immediately. The next LLM call that fails its primary provider
will try the updated chain.

---

## Full System Restart

When individual process kills and subsystem restarts are insufficient, perform a
clean restart:

```bash
# Graceful shutdown (sends SIGTERM, allows Ecto to close cleanly):
bin/osagent stop

# Wait for shutdown:
sleep 5

# Restart:
bin/osagent start

# Or in development:
pkill -f "beam.smp"  # Kill BEAM
mix run --no-halt
```

Verify recovery:
```bash
# Check HTTP API is responding:
curl http://localhost:9089/health

# Check provider availability:
curl http://localhost:9089/providers

# Run the doctor command:
mix run -e "OptimalSystemAgent.CLI.doctor()"
```
