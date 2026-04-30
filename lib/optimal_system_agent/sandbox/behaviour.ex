defmodule OptimalSystemAgent.Sandbox.Behaviour do
  @moduledoc """
  Behaviour for sandbox execution backends.

  Implement this behaviour to add a new sandbox backend (Docker, E2B, Firecracker, etc.).
  The agent uses whichever backend is configured in `~/.osa/sandbox.json` or
  application config. Default is `:host` (no sandbox — runs directly on machine).

  ## Configuration

      # config/config.exs or ~/.osa/sandbox.json
      config :optimal_system_agent, :sandbox_backend, :host
      config :optimal_system_agent, :sandbox_mode, :optional

      # Options: :host, :docker, :e2b
      # Or a custom module: MyApp.Sandbox.Custom
      # Mode options: :optional, :required
  """

  @type exec_result :: {:ok, String.t()} | {:error, String.t()}

  @doc "Check if this backend is available on the current system."
  @callback available?() :: boolean()

  @doc "Execute a command in the sandbox. Returns stdout/stderr."
  @callback execute(command :: String.t(), opts :: keyword()) :: exec_result()

  @doc "Execute a code file in the sandbox. Language auto-detected from extension."
  @callback run_file(path :: String.t(), opts :: keyword()) :: exec_result()

  @doc "Human-readable name for display."
  @callback name() :: String.t()
end
