defmodule OptimalSystemAgent.Application do
  @moduledoc """
  OTP Application supervisor for the Optimal System Agent.

  The supervision tree is organised into 4 logical subsystem supervisors
  plus the HTTP server and deferred channel startup:

    Infrastructure  — registries, pub/sub, event bus, storage, telemetry,
                      provider/tool routing, MCP integration
    Sessions        — channel adapters, event stream registry, session DynamicSupervisor
    AgentServices   — memory, workflow, orchestration, hooks, learning, scheduler, etc.
    Extensions      — opt-in subsystems: treasury, intelligence, swarm, fleet,
                      sidecars, sandbox, wallet, updater, AMQP

  The top-level strategy remains `:rest_for_one` so that a crash in
  Infrastructure (core) tears down everything above it, while each subsystem
  supervisor uses the strategy most appropriate for its children.
  """
  use Application

  require Logger

  alias OptimalSystemAgent.Channels.HTTP.Auth

  @impl true
  def start(_type, _args) do
    Application.put_env(:optimal_system_agent, :start_time, System.system_time(:second))

    # Capture the user's launch directory as the single cwd source of truth
    # (mirrors CC setOriginalCwd). Prefers OSA_ORIGINAL_CWD (exported by the TUI
    # from its launch dir) over File.cwd!(), which under `mix osa.serve` is the
    # OSA source tree, not the user's project.
    OptimalSystemAgent.Workspace.Cwd.set_original_cwd()

    # ── Phase 0: Environment & Configuration ──────────────────────────
    # Load .env file FIRST (before anything reads env vars)
    load_dotenv()

    # Load settings cascade (user → project → local → flag)
    load_settings_into_app_env()

    # Apply the merged settings "env" key to the OS environment BEFORE the
    # provider env mapping below so settings-provided vars are visible to it.
    # Re-applied live by Settings.Watcher when a settings file changes on disk.
    OptimalSystemAgent.Settings.apply_env_settings()

    # Surface settings schema/parse issues (with fix tips) once at boot.
    OptimalSystemAgent.Settings.Schema.validate_and_log()

    # Warm the ConfigFile cache (~/.osa/config.toml over config.json over defaults)
    # so its :persistent_term cache is populated and any TOML parse error surfaces
    # ONCE, early, at boot. Never crash boot on a bad config — ConfigFile already
    # logs and falls back to defaults on a parse failure; this is belt-and-braces.
    warm_config_file()

    # Read the config.toml [model] table (config.toml ONLY — see toml_model_section/0)
    # so a config.toml provider/effort/params can override the env/default chain
    # below while leaving that chain untouched when config.toml has no [model].
    toml_model = OptimalSystemAgent.ConfigFile.toml_model_section()

    # Provider resolution (precedence high → low):
    #   config.toml [model].provider  >  OSA_DEFAULT_PROVIDER env  >  app default
    # config.toml wins per the documented precedence (defaults < config.json <
    # config.toml). config.json's legacy provider is intentionally NOT consulted
    # here so that when config.toml is absent the result is byte-for-byte what the
    # old `env || default` logic produced.
    provider =
      resolve_provider(
        toml_model,
        System.get_env("OSA_DEFAULT_PROVIDER"),
        Application.get_env(:optimal_system_agent, :default_provider, :ollama)
      )

    Application.put_env(:optimal_system_agent, :default_provider, provider)

    # Map provider-specific env vars to application config
    load_provider_env(provider)

    # Reconcile the active model from every source into BOTH :default_model and
    # the provider-scoped key (e.g. :ollama_model). Without this, an .env /
    # config.json model lands only on :ollama_model while :default_model stays
    # nil, so Ollama.auto_detect_model probes and silently overwrites a
    # configured model (including :cloud models) with a local one.
    # Precedence: config.toml [model].model > config.json "model" > OLLAMA_MODEL
    # env > already-loaded. `ConfigFile.model_name/0` returns the config.toml model
    # if set, else the legacy config.json model — so when config.toml has no
    # [model].model this is EXACTLY the old `config_json_model()` top of the chain,
    # and when it does, config.toml wins (documented defaults < config.json < toml).
    # config.json remains the user's PERSISTED selection (onboarding + in-TUI
    # /switch write it) so it still beats a possibly-stale OLLAMA_MODEL env var.
    resolved_model =
      OptimalSystemAgent.ConfigFile.model_name() ||
        System.get_env("OLLAMA_MODEL") ||
        Application.get_env(:optimal_system_agent, :"#{provider}_model") ||
        Application.get_env(:optimal_system_agent, :default_model)

    if is_binary(resolved_model) and resolved_model != "" do
      Application.put_env(:optimal_system_agent, :default_model, resolved_model)
      Application.put_env(:optimal_system_agent, :"#{provider}_model", resolved_model)
    end

    # config.toml [model].effort → default reasoning-effort level. `Effort.level/0`
    # reads Settings.get(:effort_level) (session/settings cascade) FIRST and this
    # app-env key second, so config.toml sets the DEFAULT while a settings.json or
    # session override still wins — matching "defaults < config.toml".
    case resolve_effort(OptimalSystemAgent.ConfigFile.effort()) do
      nil ->
        :ok

      level ->
        Application.put_env(:optimal_system_agent, :effort_level, level)
    end

    # config.toml [model.params] → free-form generation params, stashed in app env
    # for providers to read. No-op when unset so behavior is unchanged by default.
    case OptimalSystemAgent.ConfigFile.model_params() do
      %{} = params when map_size(params) > 0 ->
        Application.put_env(:optimal_system_agent, :model_params, params)

      _ ->
        :ok
    end

    # ── Phase 1: Soul & Prompts (before anything needs the system prompt) ──
    OptimalSystemAgent.Soul.load()
    OptimalSystemAgent.PromptLoader.load()

    # ── Phase 2: ETS Tables (must exist before GenServers start) ────────
    # ETS table for Loop cancel flags — must exist before any agent session starts.
    # public + set so Loop.cancel/1 and run_loop can read/write concurrently.
    :ets.new(:osa_cancel_flags, [:named_table, :public, :set])

    # ETS table for read-before-write tracking — tracks which files have been read
    # per session so the pre_tool_use hook can nudge when writing unread files.
    :ets.new(:osa_files_read, [:named_table, :public, :set])

    # ETS table for session-layer settings (Settings.set_session). This table
    # was previously never created anywhere, so session-level settings
    # silently no-opped in production (set_session's rescue swallowed it).
    :ets.new(:osa_settings, [:named_table, :public, :set])

    # ETS cache of parsed settings files — rows {path, {mtime, size}, map}.
    # Settings.reset_cache/0 is the single reset (watcher + internal writes).
    :ets.new(:osa_settings_cache, [:named_table, :public, :set])

    # ETS table for the mid-turn steer queue (primitive #32). Rows:
    # {{session_id, seq}, text} in an ordered_set so steers drain FIFO. public so
    # the HTTP request process can queue a steer while the loop process is blocked
    # mid-turn in handle_call — the running ReactLoop drains it between steps
    # (same concurrency rationale as :osa_cancel_flags). See Loop.Steer.
    :ets.new(:osa_steer_queue, [:named_table, :public, :ordered_set])

    # WS6 — background task-notification queue. Rows {{session_id, seq}, map}
    # (ordered_set, FIFO drain). Drained beside the steer queue by a BUSY
    # ReactLoop, or by Loop.poke/1 as a synthetic turn when idle. Public for
    # the same reason as :osa_steer_queue. See Agent.TaskNotifications.
    :ets.new(:osa_task_notifications, [:named_table, :public, :ordered_set])

    # WS6 — per-task "notified" check-and-set flags ({task_id, ts}) so a
    # bash_output poll and the completion broadcast race to exactly ONE
    # <task-notification> per task.
    :ets.new(:osa_task_notified, [:named_table, :public, :set])

    # WS5 — per-session buffer of in-flight streamed text: {session_id, [delta | acc]}
    # (reverse iodata). Written by LLMClient's text_delta callback, read on a hard
    # interrupt so the partial assistant text survives the stream abort.
    :ets.new(:osa_stream_partial, [:named_table, :public, :set])

    # ETS table for ask_user_question survey answers — the HTTP endpoint writes
    # answers here, Loop.ask_user_question/4 polls and consumes them.
    :ets.new(:osa_survey_answers, [:set, :public, :named_table])

    # ETS table for caching Ollama model context window sizes — avoids repeated
    # /api/show HTTP calls since context_length doesn't change without re-pull.
    :ets.new(:osa_context_cache, [:set, :public, :named_table])

    # ETS table for survey/waitlist responses when platform DB is not enabled.
    # Rows: {unique_integer, body_map, datetime}
    :ets.new(:osa_survey_responses, [:bag, :public, :named_table])

    # ETS table for per-session provider/model overrides set via hot-swap API.
    # Rows: {session_id, provider, model}
    :ets.new(:osa_session_provider_overrides, [:named_table, :public, :set])

    # ETS table for tracking pending ask_user questions.
    # Lets GET /sessions/:id/pending_questions show when the agent is blocked.
    # Rows: {ref_string, %{session_id, question, options, asked_at}}
    :ets.new(:osa_pending_questions, [:named_table, :public, :set])

    # ETS table for subagent session counters (Orchestrator.next_subagent_number/1)
    :ets.new(:osa_subagent_counters, [:named_table, :public, :set])

    # ETS table for structured compression state (previous summary persistence)
    :ets.new(:osa_compactor_state, [:named_table, :public, :set])

    # ETS table for auto-mode safety Guardian state.
    # Rows: {{session_id, :blocks}, integer_count} and {{session_id, :paused}, true}
    # Tracks how many dangerous tool calls have been blocked in a session so the
    # Guardian can pause unattended execution after N blocks (config threshold).
    :ets.new(:osa_auto_mode, [:named_table, :public, :set])

    # ETS table for tool-call argument REASK counters (BUG A / primitive #31).
    # Rows: {{session_id, tool_name}, invalid_attempt_count}
    # ToolArgValidator caps how many times a tool is re-asked for corrected
    # arguments before returning a terminal error, bounding malformed-args loops.
    :ets.new(:osa_reask_counts, [:named_table, :public, :set])

    # ETS table for cooperative agent pause flags. Rows: {session_id, true}.
    # Checked by ReactLoop each iteration; set/cleared by POST /agents/:id/pause
    # and /resume. Replaces the unsafe :sys.suspend pause that hung status reads.
    :ets.new(:osa_agent_pause_flags, [:named_table, :public, :set])

    # Rehydrate the subagent RunStore index from ~/.osa/agent-runs so /runs and
    # task_resume survive a node restart (CC sidechain rehydrate parity). The ETS
    # table is created here (owned by the long-lived app master process) so it is
    # not lost when the transient task that first touched it exits.
    OptimalSystemAgent.Agent.RunStore.init_store()

    # Sandbox config (reads ~/.osa/sandbox.json if present)
    OptimalSystemAgent.Sandbox.Router.load_config()

    # Team coordination tables (shared task list, messaging, scratchpad)
    OptimalSystemAgent.Team.init_tables()

    # Context Mesh registry table
    OptimalSystemAgent.ContextMesh.Registry.init_table()

    # Peer protocol tables (handoffs, reviews, negotiations, discovery)
    OptimalSystemAgent.Peer.Protocol.init_table()
    OptimalSystemAgent.Peer.Review.init_table()
    OptimalSystemAgent.Peer.Negotiation.init_table()
    OptimalSystemAgent.Peer.Discovery.init_tables()

    # File locking intent broadcaster tables
    OptimalSystemAgent.FileLocking.IntentBroadcaster.init_tables()

    # Workspace session tracking table
    OptimalSystemAgent.Workspace.Session.init_table()

    # Workspace SQLite tables (workspaces + task_journals)
    OptimalSystemAgent.Workspace.Store.init()

    # ── Phase 3: Supervision Tree ────────────────────────────────────────
    children =
      platform_repo_children() ++
        [
          # General-purpose Task.Supervisor for fire-and-forget async work
          # (HTTP message dispatch, background learning, etc.)
          {Task.Supervisor, name: OptimalSystemAgent.TaskSupervisor},
          OptimalSystemAgent.Supervisors.Infrastructure,
          OptimalSystemAgent.Supervisors.Sessions,
          OptimalSystemAgent.Supervisors.AgentServices,
          OptimalSystemAgent.Supervisors.Extensions,

          # Deferred channel startup — starts configured channels in handle_continue
          OptimalSystemAgent.Channels.Starter,

          # HTTP channel — Plug/Bandit on configured port (SDK API surface)
          # Started LAST so all agent processes are ready before accepting requests
          {Bandit, plug: OptimalSystemAgent.Channels.HTTP, port: http_port(), ip: http_ip()}
        ]

    # max_restarts: 10 in 60s prevents infinite crash loops from burning CPU
    opts = [
      strategy: :rest_for_one,
      name: OptimalSystemAgent.Supervisor,
      max_restarts: 10,
      max_seconds: 60
    ]

    # Emit an ERROR-level log if the HTTP server is reachable without auth.
    Auth.warn_if_insecure()

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # ── Phase 4: Post-boot initialization ──────────────────────────
        # These run AFTER the supervision tree is fully up.

        # Run pending Ecto migrations (session_transcripts FTS5, etc.)
        run_migrations()

        # Load agent definitions (needs Tools.Registry running)
        OptimalSystemAgent.Agents.Registry.load()

        # Auto-detect best Ollama model + tier assignments
        # Guarded — if Ollama is unreachable, log and continue without spinning
        if provider == :ollama do
          try do
            OptimalSystemAgent.Providers.Ollama.auto_detect_model()
            OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
          rescue
            e -> Logger.warning("Ollama auto-detect failed: #{Exception.message(e)}")
          catch
            :exit, reason -> Logger.warning("Ollama auto-detect exit: #{inspect(reason)}")
          end
        end

        # W3/D3 — boot-time fleet recovery. Runs AFTER the supervision tree is up
        # (SessionRegistry available) so re-dispatch can spawn live loops.
        # Reconciles stale `:running` rows whose owning process died with the
        # previous daemon — so the /runs roster + fleet counts aren't inflated by
        # ghosts — and, when opted in via `:fleet_resume_on_boot` (default off),
        # re-dispatches qualifying orphaned autonomous runs under their original
        # ids from the durable per-node snapshots. Budget-capped, best-effort.
        OptimalSystemAgent.Agent.FleetResumer.resume_on_boot()

        # Signal boot complete
        Application.put_env(:optimal_system_agent, :boot_complete, true)

        Logger.info(
          "OSA boot complete (#{System.system_time(:second) - Application.get_env(:optimal_system_agent, :start_time, 0)}s)"
        )

        {:ok, pid}

      error ->
        error
    end
  end

  defp platform_repo_children do
    []
  end

  defp http_port do
    case System.get_env("OSA_HTTP_PORT") do
      nil -> Application.get_env(:optimal_system_agent, :http_port, 9089)
      port -> String.to_integer(port)
    end
  end

  # Returns the IP tuple that Bandit should bind to.
  # Defaults to {127, 0, 0, 1} (loopback) so that an unconfigured server is
  # never accidentally exposed on the network.
  # Set OSA_HTTP_IP=0.0.0.0 to bind all interfaces (requires auth to be safe).
  defp http_ip do
    ip_tuple = Application.get_env(:optimal_system_agent, :http_ip, {127, 0, 0, 1})
    ip_tuple
  end

  # Warm OptimalSystemAgent.ConfigFile at boot so its :persistent_term cache is
  # populated and a bad ~/.osa/config.toml surfaces a single warning early rather
  # than on first lazy access. Never allowed to crash boot.
  defp warm_config_file do
    OptimalSystemAgent.ConfigFile.load()
    :ok
  rescue
    e ->
      Logger.warning("[ConfigFile] boot load failed, using defaults: #{Exception.message(e)}")
      :ok
  catch
    _, reason ->
      Logger.warning("[ConfigFile] boot load failed, using defaults: #{inspect(reason)}")
      :ok
  end

  @doc false
  # Pure provider resolution — testable without booting the app.
  #   config.toml [model].provider  >  OSA_DEFAULT_PROVIDER env  >  app default
  @spec resolve_provider(map(), String.t() | nil, atom()) :: atom()
  def resolve_provider(toml_model, env_provider, app_default) do
    case Map.get(toml_model, "provider") do
      p when is_binary(p) and p != "" ->
        String.to_atom(p)

      _ ->
        case env_provider do
          nil -> app_default
          "" -> app_default
          p -> String.to_atom(p)
        end
    end
  end

  @doc false
  # Pure effort resolution — normalizes a config.toml [model].effort string to a
  # known level atom (:fast | :medium | :high | :xhigh | :ultra), or nil for
  # absent/invalid. Legacy "low"/"max" are accepted and mapped (low→fast,
  # max→xhigh) for back-compat with older config files.
  @spec resolve_effort(term()) :: :fast | :medium | :high | :xhigh | :ultra | nil
  def resolve_effort(effort) when is_binary(effort) do
    e = effort |> String.trim() |> String.downcase()

    cond do
      e in ~w(fast medium high xhigh ultra) -> String.to_atom(e)
      e == "low" -> :fast
      e == "max" -> :xhigh
      true ->
        Logger.warning("[ConfigFile] ignoring unknown [model].effort #{inspect(effort)}")
        nil
    end
  end

  def resolve_effort(_), do: nil

  defp load_dotenv do
    env_file = Path.expand("~/.osa/.env")

    if File.exists?(env_file) do
      env_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        line = String.trim(line)

        cond do
          line == "" ->
            :ok

          String.starts_with?(line, "#") ->
            :ok

          String.contains?(line, "=") ->
            [key | rest] = String.split(line, "=", parts: 2)
            value = Enum.join(rest, "=") |> String.trim() |> String.trim("\"") |> String.trim("'")
            # Only set if not already set (env vars take precedence)
            if System.get_env(String.trim(key)) == nil do
              System.put_env(String.trim(key), value)
            end

          true ->
            :ok
        end
      end)
    end
  rescue
    _ -> :ok
  end

  # Load settings from ~/.osa/settings.json into Application env
  defp load_settings_into_app_env do
    settings = OptimalSystemAgent.Settings.all()

    Enum.each(settings, fn {key, value} ->
      atom_key = if is_atom(key), do: key, else: String.to_atom(key)
      # Only set if not already configured (explicit config takes precedence)
      if Application.get_env(:optimal_system_agent, atom_key) == nil do
        Application.put_env(:optimal_system_agent, atom_key, value)
      end
    end)
  rescue
    _ -> :ok
  end

  # Run pending Ecto migrations
  defp run_migrations do
    try do
      repo = OptimalSystemAgent.Store.Repo

      if Process.whereis(repo) do
        migrations_path = Application.app_dir(:optimal_system_agent, "priv/repo/migrations")
        Ecto.Migrator.run(repo, migrations_path, :up, all: true, log: false)
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # Map {PROVIDER}_API_KEY, {PROVIDER}_MODEL, {PROVIDER}_BASE_URL env vars
  # to application config so providers can read them via Application.get_env.
  @env_mapping [{"_API_KEY", "_api_key"}, {"_MODEL", "_model"}, {"_BASE_URL", "_url"}]

  def load_provider_env(provider) do
    prefix = String.upcase(to_string(provider))

    Enum.each(@env_mapping, fn {env_suffix, app_suffix} ->
      case System.get_env(prefix <> env_suffix) do
        nil ->
          :ok

        value ->
          Application.put_env(
            :optimal_system_agent,
            String.to_atom("#{provider}#{app_suffix}"),
            value
          )
      end
    end)
  end
end
