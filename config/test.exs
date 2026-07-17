import Config

config :logger, level: :warning

# Sandbox pool removed — singleton GenServers (Memory, TaskQueue, etc.) call
# Repo from their own processes and can't do Sandbox.checkout!(), which causes
# DBConnection.OwnershipError → rest_for_one cascade → flaky "no process" failures.
# Tests use unique IDs and don't need transaction isolation.
config :optimal_system_agent, OptimalSystemAgent.Store.Repo, pool_size: 2

# Disable all LLM calls in tests so deterministic paths are always
# exercised and tests remain fast, repeatable, and provider-independent.
config :optimal_system_agent, classifier_llm_enabled: false
config :optimal_system_agent, knowledge_backend: MiosaKnowledge.Backend.ETS
config :optimal_system_agent, compactor_llm_enabled: false
# Use a different HTTP port in tests to avoid conflicts
config :optimal_system_agent, http_port: 0

# Durable execution (primitive #27): isolate the per-step durable log under the
# system tmp dir so tests never write to ~/.osa. `durable_execution` stays at its
# default (true) so the idempotency/replay path is exercised by its own tests.
config :optimal_system_agent,
  durable_log_dir: Path.join(System.tmp_dir!(), "osa-test-durable")

# Per-run test secret — no hardcoded secrets
config :optimal_system_agent,
  shared_secret: "osa-test-#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"

# Disable OpenComputers supervisor in tests — FrameRouter and PtyExecutor are
# started explicitly per test so named process conflicts are avoided.
config :optimal_system_agent, open_computers_enabled: false

# Interactive permission prompts (default 'ask' mode round-trip) are OFF in the
# test suite: no TUI is attached to respond, so a mutating tool must not park.
# The permission round-trip is exercised by its own tests, which flip this on
# explicitly. With it off, the tier decision stands (prior behavior preserved).
config :optimal_system_agent, interactive_permissions: false

# Isolate the saved permission-rule store so save_rule/2 tests never touch the
# real ~/.osa/permissions.json.
config :optimal_system_agent,
  permissions_file: Path.join(System.tmp_dir!(), "osa-test-permissions.json")
