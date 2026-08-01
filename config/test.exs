import Config

config :logger, level: :warning

# The post-edit format+diagnostics loop shells out to formatters/compilers and
# rewrites edited files in place. The suite exercises the edit tools heavily
# against temp fixtures, so keep it OFF here (its own unit tests drive
# Verify.PostEdit directly with an injected exec seam). Prod default stays on.
config :optimal_system_agent, post_edit_verify: [enabled: false]

# Sandbox pool removed — singleton GenServers (Memory, TaskQueue, etc.) call
# Repo from their own processes and can't do Sandbox.checkout!(), which causes
# DBConnection.OwnershipError → rest_for_one cascade → flaky "no process" failures.
# Tests use unique IDs and don't need transaction isolation.
#
# Isolate the Store.Repo database under the system tmp dir so tests never touch
# the real ~/.osa/osa.db (matching the durable_log_dir / permissions_file
# isolation below). Crucially this also gives every run a FRESH database: the
# suite seeds transcript/session rows keyed by `System.unique_integer/1`, which
# is only unique *within* a VM instance — against a persistent DB, ids from a
# prior run collide with leftover rows and corrupt exact-count assertions
# (e.g. session fork message_count). The file is deleted here, before the Repo
# connects at boot; migrations recreate the schema on startup.
#
# The path is also per-RUN, not a single fixed name. This deletion happens at
# config-load time, so with one shared filename a second `mix test` starting
# while a first is still running deletes the database out from under it, and the
# already-connected Repo fails every later query with "no such table: …". That
# is not hypothetical: it turns a green suite into dozens of unrelated
# persistence failures that look like a code regression. Runs are already
# isolated by `OSA_HTTP_PORT`, so key the database off the same knob (falling
# back to the OS pid) and concurrent suites stop clobbering each other.
test_db_tag = System.get_env("OSA_HTTP_PORT") || System.pid()
test_db_path = Path.join(System.tmp_dir!(), "osa-test-#{test_db_tag}.db")

for suffix <- ["", "-shm", "-wal"] do
  _ = File.rm(test_db_path <> suffix)
end

# Per-run naming means nothing ever reuses (and therefore ever cleans up) an old
# file, so sweep databases left by runs that finished more than a day ago. Only
# age is considered — a file younger than that may belong to a suite running
# right now, which is the exact thing this scheme exists to protect.
stale_before = System.os_time(:second) - 86_400

for stale <- Path.wildcard(Path.join(System.tmp_dir!(), "osa-test-*.db*")),
    match?({:ok, %{mtime: mtime}} when mtime < stale_before, File.stat(stale, time: :posix)) do
  _ = File.rm(stale)
end

config :optimal_system_agent, OptimalSystemAgent.Store.Repo,
  pool_size: 2,
  database: test_db_path

# Disable all LLM calls in tests so deterministic paths are always
# exercised and tests remain fast, repeatable, and provider-independent.
config :optimal_system_agent, classifier_llm_enabled: false

# Disable the settings file watcher in tests — the suite changes cwd per test,
# so the watcher would see every project-path change as an external edit and
# fire spurious settings_changed events / cache resets. The watcher's own test
# re-enables it explicitly around a supervised instance.
config :optimal_system_agent, settings_watcher_enabled: false

# Disable Onboarding.live_env/1's ~/.osa/.env (and ./.env) disk fallback in
# tests — same reasoning as the .env FILE load config/runtime.exs itself
# skips under config_env() == :test: the suite must never read the
# OPERATOR's real ~/.osa/.env (provider keys, default provider, ...) and
# become flaky depending on whose machine runs it. System.get_env is still
# consulted; tests exercise the live-env-var path via System.put_env.
config :optimal_system_agent, live_env_file_fallback: false

# Isolate the ~/.osa bootstrap dir so tests NEVER touch the operator's real
# config. Without this, HTTP route tests that exercise POST /switch call
# persist_model_selection, which writes ~/.osa/config.json — silently clobbering
# the user's real model selection every time the suite runs.
config :optimal_system_agent,
  bootstrap_dir: Path.join(System.tmp_dir!(), "osa-test-bootstrap")

# Model catalog: no network fetch in tests — deterministic, bundled-only.
# Point the on-disk cache at a path that never exists so the catalog's tier-1
# cache lookup (`fresh_cache/0`) always misses and it falls through to the
# bundled `priv/catalog/models_dev.json`. Without this, a developer machine with
# a warm `~/.osa/cache/models.json` (a real live fetch, WITH pricing) would win
# over the bundled snapshot and break the "bundled ships no pricing" guard — the
# suite would then pass on clean CI but fail locally. Disabling network alone is
# not enough; the cache tier must be neutralized too.
config :optimal_system_agent, disable_models_fetch: true

config :optimal_system_agent,
  models_cache_path: Path.join(System.tmp_dir!(), "osa-test-no-such-models-cache.json")

# External-tool MCP discovery (Codex/Claude/Cursor) is OFF in the suite so tests
# never load the operator's real ~/.codex, ~/.claude, ~/.cursor config from
# $HOME. The discovery unit test enables it explicitly via a fake home override.
config :optimal_system_agent, mcp_discovery_enabled: false

# Never launch a real browser from the suite. `Utils.Browser.open/1` shells out
# to `xdg-open`/`open`, so on a developer's DESKTOP machine (real $DISPLAY) any
# test that exercises it genuinely opens a tab — which is how a placeholder
# OAuth URL from a test fixture kept popping up on the user's screen every time
# the suite ran. The Browser unit test re-enables this explicitly, with PATH
# pointed at a harmless stub opener.
config :optimal_system_agent, browser_open_enabled: false

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
# explicitly.
config :optimal_system_agent, interactive_permissions: false

# WS1 fail-closed: non-interactive 'ask' decisions now auto-REJECT unless this
# explicit bypass is set. The suite opts out so mutating-tool tests keep running
# without a TUI; the fail-closed path is exercised by its own regression tests.
config :optimal_system_agent, non_interactive_permission_bypass: true

# Isolate the saved permission-rule store so save_rule/2 tests never touch the
# real ~/.osa/permissions.json.
config :optimal_system_agent,
  permissions_file: Path.join(System.tmp_dir!(), "osa-test-permissions.json")

# Isolate the sticky permission-mode store the same way: without this, tests
# that set :overdrive persisted to the real ~/.osa/permission_mode.json (shared
# with the live daemon) and recycled session ids collided across runs into false
# non-:ask defaults.
config :optimal_system_agent,
  permission_mode_file: Path.join(System.tmp_dir!(), "osa-test-permission-mode.json")
