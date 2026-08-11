defmodule OptimalSystemAgent.CLI.Doctor do
  @moduledoc """
  Health check for the `osagent doctor` CLI subcommand.

  Runs lightweight diagnostics without starting the full OTP application.
  Checks runtime, CLI wrapper, TUI binary, HTTP API, provider availability, GoldRush
  event router, working directory, PostgreSQL, and AMQP connectivity.
  """

  @app :optimal_system_agent
  @separator "────────────────────────────────"

  @doc """
  Dispatch `osa doctor [--config]`.

  Bare `doctor` keeps its existing behaviour exactly. `--config` prints the
  setup-inspection report instead — which markdown files are loaded from where,
  which skills surface and why, and which layer produced each effective setting.
  It is a separate report rather than extra rows because it answers a different
  question: `run/0` asks "is OSA healthy", `--config` asks "what is OSA
  actually reading".
  """
  @spec run([String.t()]) :: :ok
  def run(args) when is_list(args) do
    cond do
      "--config" in args or "config" in args ->
        OptimalSystemAgent.CLI.Doctor.Inspection.run()

      "--all" in args ->
        run()
        OptimalSystemAgent.CLI.Doctor.Inspection.run()

      true ->
        run()
    end
  end

  @doc "Run all health checks and print the report."
  def run do
    # Best-effort: works whether or not the OTP app is already running (the
    # TUI calls this in-process, the CLI subcommand from a cold VM).
    _ = Application.load(@app)
    _ = Application.ensure_all_started(:req)

    IO.puts("")
    IO.puts("OSA Health Check")
    IO.puts(@separator)

    checks = checks()

    Enum.each(checks, &print_check/1)

    IO.puts("")

    failed = Enum.count(checks, fn {status, _, _} -> status == :fail end)

    status_line =
      cond do
        failed > 0 -> "Status: NOT READY (#{failed} check(s) failed)"
        true -> "Status: READY"
      end

    IO.puts(status_line)
    IO.puts("")
  end

  @doc """
  Run every health check and return the raw `[{status, name, detail}]` list.

  `status` is one of `:pass | :fail | :optional`. Shared by both the printed
  CLI report (`run/0`) and the structured `/doctor` HTTP endpoint (`report/0`),
  so the TUI and the terminal always see the same diagnostics.
  """
  @spec checks() :: [{:pass | :fail | :optional, String.t(), String.t()}]
  def checks do
    _ = Application.ensure_all_started(:req)

    [
      check_runtime(),
      check_version(),
      check_cli(),
      check_tui(),
      check_api(),
      check_config(),
      check_model(),
      check_provider(),
      check_miosa_cli(),
      check_event_router(),
      check_working_directory(),
      check_postgresql(),
      check_amqp()
    ] ++ legacy_anthropic_oauth_checks() ++ onboarding_checks()
  end

  # Only ever appears for a user who was signed in with the removed Anthropic
  # subscription flow — everyone else sees no extra row. `osa doctor` runs from
  # a cold VM too (no Application.start), so purge here as well as at boot.
  defp legacy_anthropic_oauth_checks do
    alias OptimalSystemAgent.Auth.LegacyAnthropicOAuth

    purged = LegacyAnthropicOAuth.purge() == :purged

    if purged or LegacyAnthropicOAuth.purged?() do
      # `:optional`, not `:fail` — a user who ALSO has an API key configured is
      # perfectly healthy and must not be told "NOT READY". The row exists to
      # explain the change; `check_provider` is what reports an actual
      # missing-credential failure.
      [{:optional, "Anthropic sign-in", LegacyAnthropicOAuth.notice()}]
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Structured, JSON-friendly health report for the `/doctor` HTTP endpoint.

  Returns `%{ready: bool, status: "ready"|"not_ready", failed: n, checks: [...]}`
  where each check is `%{name, status, detail}` with a string `status`.
  """
  @spec report() :: %{
          ready: boolean(),
          status: String.t(),
          failed: non_neg_integer(),
          checks: [%{name: String.t(), status: String.t(), detail: String.t()}]
        }
  def report do
    results = checks()
    failed = Enum.count(results, fn {status, _, _} -> status == :fail end)

    %{
      ready: failed == 0,
      status: if(failed == 0, do: "ready", else: "not_ready"),
      failed: failed,
      checks:
        Enum.map(results, fn {status, name, detail} ->
          %{name: name, status: to_string(status), detail: detail}
        end)
    }
  end

  # Fold Onboarding.doctor_checks/0 (config file + workspace templates) into the
  # unified check list so `.env` presence + seeded workspace show up in both the
  # CLI report and the TUI panel.
  defp onboarding_checks do
    OptimalSystemAgent.Onboarding.doctor_checks()
    |> Enum.map(fn
      {:ok, label} -> {:pass, "Workspace", label}
      {:error, label, hint} -> {:fail, "Workspace", "#{label} — #{hint}"}
      {:error, label} -> {:fail, "Workspace", label}
    end)
  rescue
    _ -> []
  end

  defp check_version do
    vsn =
      case Application.spec(@app, :vsn) do
        nil -> read_version_file()
        vsn -> to_string(vsn)
      end

    {:pass, "Version", "OSA v#{vsn}"}
  end

  defp read_version_file do
    case File.read(Path.expand("VERSION")) do
      {:ok, v} -> String.trim(v)
      _ -> "unknown"
    end
  end

  # Config + provider keys: at least one provider credential (or local Ollama)
  # should be reachable. Purely local check — never dials out.
  defp check_config do
    env_file = Path.join(Path.expand("~/.osa"), ".env")

    key_vars =
      ~w(MIOSA_API_KEY OLLAMA_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GROQ_API_KEY)

    configured_keys = Enum.filter(key_vars, fn v -> present?(System.get_env(v)) end)

    cond do
      not File.exists?(env_file) ->
        {:fail, "Config", "~/.osa/.env missing — run setup"}

      configured_keys != [] ->
        {:pass, "Config", "#{length(configured_keys)} provider key(s) set"}

      true ->
        {:optional, "Config", ".env present, no cloud keys (local Ollama ok)"}
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(v) when is_binary(v), do: true

  # The EFFECTIVE model and WHICH file supplied it.
  #
  # Three files can specify a model (`~/.osa/config.toml`, `~/.osa/config.json`,
  # `~/.osa/.env`) and nothing used to report which one won. A user staring at
  # three disagreeing files had no way to debug the chain short of reading
  # `application.ex` — so they guessed, and so did the agent. Printing the
  # winner *and its origin* makes the precedence chain self-documenting.
  defp check_model do
    id = OptimalSystemAgent.Runtime.Identity.describe()

    ctx =
      case id.context_window do
        n when is_integer(n) -> ", #{ctx_label(n)} ctx"
        _ -> ", ctx unknown"
      end

    url = if id.base_url, do: " → #{id.base_url}", else: ""

    {:pass, "Model", "#{id.model} (from #{id.source_label}#{ctx})#{url}"}
  rescue
    _ -> {:optional, "Model", "unresolved"}
  catch
    :exit, _ -> {:optional, "Model", "unresolved"}
  end

  defp ctx_label(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp ctx_label(n) when n >= 1_000, do: "#{div(n, 1000)}k"
  defp ctx_label(n), do: to_string(n)

  # ── Check Implementations ──────────────────────────────────────

  defp check_runtime do
    otp_release = :erlang.system_info(:otp_release) |> to_string()
    {:pass, "Runtime", "OTP #{otp_release}"}
  end

  defp check_cli do
    cond do
      path = System.find_executable("osa") ->
        {:pass, "CLI", "osa on PATH (#{path})"}

      path = System.find_executable("osagent") ->
        {:pass, "CLI", "osagent on PATH (#{path})"}

      path = repo_cli_path() ->
        {:pass, "CLI", "repo wrapper (#{abbreviate_home(path)})"}

      true ->
        {:fail, "CLI", "osa not on PATH and bin/osa not executable"}
    end
  end

  defp check_tui do
    # Check for the Rust TUI binary first, then Go TUI
    priv_dir = find_priv_dir()

    rust_tui =
      if priv_dir,
        do: Path.join([priv_dir, "rust", "tui", "target", "release", "osagent"]),
        else: nil

    go_tui = if priv_dir, do: Path.join([priv_dir, "go", "tui-v2", "osa"]), else: nil

    cond do
      rust_tui && File.exists?(rust_tui) && executable?(rust_tui) ->
        version = tui_version(rust_tui)
        {:pass, "TUI", version}

      go_tui && File.exists?(go_tui) && executable?(go_tui) ->
        version = tui_version(go_tui)
        {:pass, "TUI", version}

      rust_tui && File.exists?(rust_tui) ->
        {:fail, "TUI", "found but not executable"}

      go_tui && File.exists?(go_tui) ->
        {:fail, "TUI", "found but not executable"}

      true ->
        {:fail, "TUI", "binary not found"}
    end
  end

  defp check_api do
    port = resolve_http_port()
    api_status(OptimalSystemAgent.Net.Port.holder_kind(port), port)
  end

  @doc """
  Map a port `holder` classification into the `{status, "API", detail}` tuple
  the report prints. Public so the three distinct states can be tested without
  standing up real sockets:

    * `:osa`     — OSA is running and answering → `:pass`
    * `:free`    — port is free, OSA simply isn't running → `:fail` (start it)
    * `:foreign` — port is occupied by a NON-OSA process (the blind spot the
      old TCP-connect check reported as a generic "responding") → `:fail` with
      the actionable fix.
  """
  @spec api_status(OptimalSystemAgent.Net.Port.holder(), non_neg_integer()) ::
          {:pass | :fail, String.t(), String.t()}
  def api_status(kind, port) do
    case kind do
      :osa ->
        {:pass, "API", ":#{port} (OSA responding)"}

      :free ->
        {:fail, "API", ":#{port} (OSA not running — start with 'osa')"}

      :foreign ->
        {:fail, "API",
         ":#{port} in use by another process — free it (ss -ltnp | grep #{port}) or set OSA_HTTP_PORT"}
    end
  end

  defp check_provider do
    # Try Ollama first (most common local provider). OLLAMA_URL is the var the
    # rest of the app reads (onboarding, providers, setup) — OLLAMA_HOST was a
    # misalignment that made doctor probe the wrong endpoint.
    ollama_url = System.get_env("OLLAMA_URL") || "http://localhost:11434"

    case detect_ollama(ollama_url) do
      {:ok, _first_pulled_model} ->
        {:pass, "Provider", "Ollama (#{configured_model_name(:ollama)})"}

      :no_models ->
        {:pass, "Provider", "Ollama (no models pulled)"}

      :unreachable ->
        # Check for cloud provider API keys
        cond do
          System.get_env("ANTHROPIC_API_KEY") ->
            {:pass, "Provider", "Anthropic (#{configured_model_name(:anthropic)})"}

          System.get_env("OPENAI_API_KEY") ->
            {:pass, "Provider", "OpenAI (#{configured_model_name(:openai)})"}

          System.get_env("GROQ_API_KEY") ->
            {:pass, "Provider", "Groq (#{configured_model_name(:groq)})"}

          has_lm_studio?() ->
            {:pass, "Provider", "LM Studio (responding)"}

          true ->
            {:fail, "Provider", "no provider detected"}
        end
    end
  end

  @doc """
  Resolve the model OSA is actually configured to use for `fallback_provider`,
  the SAME way `GET /health` does (`lib/optimal_system_agent/channels/http.ex`
  ~L92-116): an explicit `default_model` app-env value wins; otherwise fall
  back to the resolved provider's catalog default model; otherwise the
  provider name itself. Public so `osa doctor` and `/health` can never
  silently disagree about which model is configured — this used to print the
  first model returned by `GET /api/tags` instead, which could be any locally
  pulled model with no relation to `OSA_MODEL`.
  """
  @spec configured_model_name(atom()) :: String.t()
  def configured_model_name(fallback_provider) do
    case Application.get_env(:optimal_system_agent, :default_model) do
      nil ->
        resolved_provider =
          Application.get_env(:optimal_system_agent, :default_provider, fallback_provider)

        try do
          case OptimalSystemAgent.Providers.Registry.provider_info(resolved_provider) do
            {:ok, info} -> to_string(info.default_model)
            _ -> to_string(resolved_provider)
          end
        rescue
          _ -> to_string(resolved_provider)
        catch
          :exit, _ -> to_string(resolved_provider)
        end

      m ->
        to_string(m)
    end
  end

  defp check_miosa_cli do
    # MIOSA CLI (platform account) — installed? logged-in? Optional integration.
    alias OptimalSystemAgent.MIOSA.CLI, as: MiosaCLI

    cond do
      not MiosaCLI.installed?() ->
        {:optional, "MIOSA CLI", "not installed (#{MiosaCLI.install_command()})"}

      not MiosaCLI.auth_configured?() ->
        {:optional, "MIOSA CLI", "installed but not logged in (#{MiosaCLI.login_command()})"}

      true ->
        version = MiosaCLI.version() || "installed"
        {:pass, "MIOSA CLI", "#{version} (logged in)"}
    end
  end

  defp check_event_router do
    # Check if :glc (goldrush) is available and the router module can be loaded
    case Code.ensure_loaded(:glc) do
      {:module, :glc} ->
        {:pass, "Event router", "compiled"}

      {:error, _} ->
        {:fail, "Event router", "goldrush not compiled"}
    end
  end

  defp check_working_directory do
    workspace = Path.expand("~/.osa/workspace")

    cond do
      File.dir?(workspace) ->
        # Abbreviate home directory for display
        display = abbreviate_home(workspace)
        {:pass, "Working directory", display}

      true ->
        {:fail, "Working directory", "~/.osa/workspace not found"}
    end
  end

  defp check_postgresql do
    if System.get_env("DATABASE_URL") do
      # Just verify the env var is set — don't attempt a connection
      # since we haven't started the full app
      {:pass, "PostgreSQL", "configured (DATABASE_URL set)"}
    else
      {:optional, "PostgreSQL", "not configured (optional)"}
    end
  end

  defp check_amqp do
    if System.get_env("AMQP_URL") do
      {:pass, "AMQP", "configured (AMQP_URL set)"}
    else
      {:optional, "AMQP", "not configured (optional)"}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp print_check({status, name, detail}) do
    icon =
      case status do
        :pass -> "\u2713"
        :fail -> "\u2717"
        :optional -> "\u25CB"
      end

    # Pad name + dots to 24 chars for alignment
    label = " #{name} "
    dots_needed = max(24 - String.length(label), 3)
    padded = "#{label}#{String.duplicate(".", dots_needed)}"
    IO.puts("#{icon}#{padded} #{detail}")
  end

  defp find_priv_dir do
    case :code.priv_dir(@app) do
      {:error, _} ->
        # Fallback for dev mode
        if File.dir?("priv"), do: Path.expand("priv"), else: nil

      dir ->
        to_string(dir)
    end
  end

  defp repo_cli_path do
    candidates =
      [
        Path.expand("bin/osa"),
        Path.expand("../bin/osa", find_priv_dir() || File.cwd!())
      ]

    Enum.find(candidates, fn path -> File.exists?(path) and executable?(path) end)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{access: access}} when access in [:read_write, :read] ->
        # Check execute permission via the mode bits
        case File.stat(path) do
          {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
          _ -> false
        end

      _ ->
        false
    end
  end

  defp tui_version(path) do
    case System.cmd(path, ["--version"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> "found"
    end
  rescue
    _ -> "found"
  end

  defp resolve_http_port do
    # Delegate to the shared helper so doctor, boot preflight, and onboarding
    # resolve the port identically.
    OptimalSystemAgent.Net.Port.configured_http_port()
  end

  defp detect_ollama(base_url) do
    case Req.get("#{base_url}/api/tags", receive_timeout: 3_000) do
      {:ok, %{status: 200, body: %{"models" => [first | _]}}} ->
        {:ok, first["name"] || "unknown"}

      {:ok, %{status: 200, body: %{"models" => []}}} ->
        :no_models

      _ ->
        :unreachable
    end
  rescue
    _ -> :unreachable
  end

  defp has_lm_studio? do
    # LM Studio typically runs on port 1234
    case :gen_tcp.connect(~c"127.0.0.1", 1234, [], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp abbreviate_home(path) do
    home = System.user_home!()

    if String.starts_with?(path, home) do
      "~" <> String.trim_leading(path, home)
    else
      path
    end
  end
end
