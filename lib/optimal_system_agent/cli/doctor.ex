defmodule OptimalSystemAgent.CLI.Doctor do
  @moduledoc """
  Health check for the `osagent doctor` CLI subcommand.

  Runs lightweight diagnostics without starting the full OTP application.
  Checks runtime, TUI binary, HTTP API, provider availability, GoldRush
  event router, working directory, PostgreSQL, and AMQP connectivity.
  """

  @app :optimal_system_agent
  @http_port 9089
  @separator "────────────────────────────────"

  @doc "Run all health checks and print the report."
  def run do
    Application.load(@app)

    # Start minimal deps for HTTP checks
    {:ok, _} = Application.ensure_all_started(:req)

    IO.puts("")
    IO.puts("OSA Health Check")
    IO.puts(@separator)

    checks = [
      check_runtime(),
      check_tui(),
      check_api(),
      check_provider(),
      check_event_router(),
      check_working_directory(),
      check_postgresql(),
      check_amqp()
    ]

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

  # ── Check Implementations ──────────────────────────────────────

  defp check_runtime do
    otp_release = :erlang.system_info(:otp_release) |> to_string()
    {:pass, "Runtime", "OTP #{otp_release}"}
  end

  defp check_tui do
    # Check for the Rust TUI binary first, then Go TUI
    priv_dir = find_priv_dir()

    rust_tui = if priv_dir, do: Path.join([priv_dir, "rust", "tui", "target", "release", "osa-tui"]), else: nil
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

    case :gen_tcp.connect(~c"127.0.0.1", port, [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:pass, "API", ":#{port} (responding)"}

      {:error, _} ->
        {:fail, "API", ":#{port} (not responding)"}
    end
  end

  defp check_provider do
    # Try Ollama first (most common local provider)
    ollama_url = System.get_env("OLLAMA_HOST") || "http://localhost:11434"

    case detect_ollama(ollama_url) do
      {:ok, model} ->
        {:pass, "Provider", "Ollama (#{model})"}

      :no_models ->
        {:pass, "Provider", "Ollama (no models pulled)"}

      :unreachable ->
        # Check for cloud provider API keys
        cond do
          System.get_env("ANTHROPIC_API_KEY") ->
            {:pass, "Provider", "Anthropic (API key set)"}

          System.get_env("OPENAI_API_KEY") ->
            {:pass, "Provider", "OpenAI (API key set)"}

          System.get_env("GROQ_API_KEY") ->
            {:pass, "Provider", "Groq (API key set)"}

          has_lm_studio?() ->
            {:pass, "Provider", "LM Studio (responding)"}

          true ->
            {:fail, "Provider", "no provider detected"}
        end
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
    case System.get_env("OSA_HTTP_PORT") do
      nil ->
        Application.get_env(@app, :http_port, @http_port)

      port_str ->
        case Integer.parse(port_str) do
          {port, _} -> port
          :error -> @http_port
        end
    end
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
