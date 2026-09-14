defmodule Mix.Tasks.Osa.Serve do
  @moduledoc """
  Start the OSA backend HTTP server without the built-in CLI.

  Use this when connecting the Go TUI or other external clients.

  Usage: mix osa.serve
  """
  use Mix.Task
  require Logger

  @shortdoc "Start HTTP backend (no CLI)"

  @impl true
  def run(_args) do
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")

    # Seed workspace templates on first run (never blocks)
    OptimalSystemAgent.Onboarding.seed_workspace()

    if Application.get_env(:optimal_system_agent, :default_provider) == :ollama do
      OptimalSystemAgent.Providers.Ollama.auto_detect_model()
      OptimalSystemAgent.Agent.Tier.detect_ollama_tiers()
    end

    # Report the same runtime-resolved port Application used to bind Bandit.
    # Reading app env directly lies whenever OSA_PORT / OSA_HTTP_PORT overrides
    # it (and prints 0 in the test profile even when a concrete port was bound).
    port = OptimalSystemAgent.Net.Port.configured_http_port()
    safe_puts("OSA backend serving on http://localhost:#{port}")
    safe_puts("Connect with: cd priv/go/tui-v2 && ./osa")
    safe_puts("Or: curl http://localhost:#{port}/health")
    Process.sleep(:infinity)
  end

  # Guard against lost console HANDLE on Windows (backgrounded processes,
  # piped output, or closed terminal windows).  Erlang raises ErlangError
  # wrapping :enotsup / :eio when the prim_tty port loses its CONOUT$
  # handle.  Silently drop the line rather than crash the VM.
  defp safe_puts(msg) do
    IO.puts(msg)
  rescue
    ErlangError -> :ok
  catch
    :error, :enotsup -> :ok
    :error, :eio -> :ok
  end
end
