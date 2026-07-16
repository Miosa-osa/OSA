defmodule OptimalSystemAgent.Sandbox.Behaviour do
  @moduledoc """
  Behaviour for sandbox execution backends.

  Implement this behaviour to add a new sandbox backend (Docker, E2B, MIOSA,
  Vercel, Firecracker, etc.). The agent uses whichever backend is configured in
  `~/.osa/sandbox.json` or application config. Default is `:host` (no sandbox —
  runs directly on the machine).

  ## Core vs optional callbacks

  The behaviour is split into a small **required core** that every backend must
  implement, and a set of **optional callbacks** that only cloud/persistent
  backends need. This keeps trivial backends (`:host`, `:docker`) simple: they
  implement four functions and nothing else. Cloud backends (`:e2b`, `:miosa`,
  `:vercel`) opt into the richer session lifecycle.

  ### Required (core)

    * `available?/0` — is this backend usable right now?
    * `execute/2`    — run a shell command, return stdout/stderr.
    * `run_file/2`   — run a code file (language auto-detected from extension).
    * `name/0`       — human-readable display name.

  ### Optional (session lifecycle + filesystem + networking)

    * `create/1`       — provision a reusable sandbox session.
    * `destroy/1`      — tear a session down.
    * `write_file/3`   — write a file into a live session.
    * `read_file/2`    — read a file back out of a live session.
    * `expose_port/2`  — expose a port and return a public preview URL.

  The `Router` uses `create/1` + `destroy/1` for **warm-sandbox reuse**: instead
  of creating and destroying a fresh sandbox on every command, a backend that
  supports sessions can keep one alive across many commands (much lower latency,
  and required for persistent/stateful workloads). When a backend does **not**
  implement an optional callback, the Router (and any caller) must **degrade
  gracefully** — e.g. fall back to the stateless `execute/2` one-shot path, or
  surface a clear "not supported by this backend" error — never crash. Use
  `supports?/2` to feature-detect before calling an optional callback.

  ## Configuration

      # config/config.exs or ~/.osa/sandbox.json
      config :optimal_system_agent, :sandbox_backend, :miosa
      config :optimal_system_agent, :sandbox_mode, :optional

      # Built-in options: :host, :docker, :e2b, :miosa, :vercel
      # Or a custom module: MyApp.Sandbox.Custom
      # Mode options: :optional, :required
  """

  @typedoc "Result of a command/file execution: `{:ok, stdout}` or `{:error, reason}`."
  @type exec_result :: {:ok, String.t()} | {:error, String.t()}

  @typedoc """
  An opaque handle to a live sandbox session.

  Backends decide the shape (a map, a struct, a pid, a bare id). Callers must
  treat it as opaque and only pass it back to the same backend's callbacks.
  """
  @type session :: term()

  # --- Required core ---

  @doc "Check if this backend is available on the current system."
  @callback available?() :: boolean()

  @doc "Execute a command in the sandbox. Returns stdout/stderr."
  @callback execute(command :: String.t(), opts :: keyword()) :: exec_result()

  @doc "Execute a code file in the sandbox. Language auto-detected from extension."
  @callback run_file(path :: String.t(), opts :: keyword()) :: exec_result()

  @doc "Human-readable name for display."
  @callback name() :: String.t()

  # --- Optional: session lifecycle + filesystem + networking ---

  @doc """
  Provision a reusable sandbox session for warm reuse.

  Returns `{:ok, session}` where `session` is an opaque handle passed back to
  `execute/2` (via the `:session` opt), `destroy/1`, `write_file/3`,
  `read_file/2`, and `expose_port/2`.
  """
  @callback create(opts :: keyword()) :: {:ok, session()} | {:error, String.t()}

  @doc "Tear down a previously created session."
  @callback destroy(session :: session()) :: :ok | {:error, String.t()}

  @doc "Write `content` to `path` inside a live session."
  @callback write_file(session :: session(), path :: String.t(), content :: String.t()) ::
              :ok | {:error, String.t()}

  @doc "Read the file at `path` out of a live session."
  @callback read_file(session :: session(), path :: String.t()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Expose `port` from the session and return a public preview URL.

  Returns `{:ok, preview_url}`.
  """
  @callback expose_port(session :: session(), port :: non_neg_integer()) ::
              {:ok, String.t()} | {:error, String.t()}

  @optional_callbacks create: 1,
                      destroy: 1,
                      write_file: 3,
                      read_file: 2,
                      expose_port: 2

  @doc """
  Feature-detect an optional callback on a backend module.

  Returns `true` only if `mod` actually exports `fun/arity`, so callers can
  degrade gracefully when a backend doesn't implement an optional capability.

      iex> Behaviour.supports?(Sandbox.MIOSA, :create, 1)
      true
      iex> Behaviour.supports?(Sandbox.Host, :expose_port, 2)
      false
  """
  @spec supports?(module(), atom(), arity()) :: boolean()
  def supports?(mod, fun, arity)
      when is_atom(mod) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end
end
