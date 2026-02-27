defmodule OptimalSystemAgent.Sandbox.Executor do
  @moduledoc """
  Unified execution interface for sandboxed skill commands.

  This is the single entry-point that `ShellExecute` (and any other skill)
  calls instead of invoking `System.cmd` directly.

  ## Routing logic

  ```
  sandbox_enabled? AND mode == :docker AND Docker.available?
    → Docker.execute/2  (full OS-level isolation)

  sandbox_enabled? AND mode == :docker AND Docker NOT available
    → {:error, "Docker sandbox enabled but Docker is not available"}
    (caller decides whether to fall back or surface the error to the user)

  sandbox_enabled? AND mode == :beam
    → beam_execute/2  (BEAM Task + timeout, no Docker)

  sandbox_enabled? == false (default)
    → beam_execute/2  (legacy behaviour, unchanged)
  ```

  ## Defense in depth

  The existing command blocklist + pattern checks in `ShellExecute` run
  **before** this module is called. The sandbox is a second, independent
  layer — not a replacement for those checks.
  """

  require Logger

  alias OptimalSystemAgent.Sandbox.{Config, Docker, Wasm}

  @type exec_result ::
          {:ok, output :: String.t()}
          | {:ok, output :: String.t(), exit_code :: non_neg_integer()}
          | {:error, reason :: String.t()}

  @doc """
  Execute `command` (a shell string) according to the current sandbox config.

  ## Options

  All options are forwarded to the underlying backend:

  - `:timeout`    — ms, default 30_000
  - `:cwd`        — working directory (BEAM mode only; Docker always uses /workspace)
  - `:network`    — override network flag for this call (Docker mode)
  - `:image`      — override container image for this call (Docker mode)
  - `:extra_env`  — `[{"KEY", "val"}]` env vars to inject (Docker mode)
  - `:workspace`  — override host workspace path (Docker mode)

  ## Return values

  - `{:ok, output, exit_code}` — completed; caller should check exit_code
  - `{:error, reason}`         — could not start/connect to executor
  """
  @spec execute(String.t(), keyword()) :: exec_result()
  def execute(command, opts \\ []) do
    config = Config.from_config()

    cond do
      config.enabled and config.mode == :docker and Docker.available?() ->
        Logger.debug("[Sandbox.Executor] Routing to Docker sandbox")
        docker_opts = config_to_docker_opts(config, opts)
        Docker.execute(command, docker_opts)

      config.enabled and config.mode == :docker ->
        Logger.error(
          "[Sandbox.Executor] Docker sandbox is enabled but Docker daemon is unreachable"
        )

        {:error,
         "Docker sandbox enabled but Docker is not available. " <>
           "Either start Docker or set OSA_SANDBOX_ENABLED=false."}

      config.enabled and config.mode == :wasm and Wasm.available?() ->
        Logger.debug("[Sandbox.Executor] Routing to WASM sandbox")
        Wasm.execute(command, opts)

      config.enabled and config.mode == :wasm ->
        Logger.error("[Sandbox.Executor] WASM sandbox enabled but wasmtime is not available")

        {:error,
         "WASM sandbox enabled but wasmtime is not available. Install wasmtime or set OSA_SANDBOX_MODE=beam."}

      config.enabled and config.mode == :beam ->
        Logger.debug("[Sandbox.Executor] Routing to BEAM sandbox (mode=:beam)")
        beam_execute(command, opts)

      true ->
        # Sandbox disabled — use existing BEAM process execution (unchanged behaviour)
        Logger.debug("[Sandbox.Executor] Sandbox disabled — BEAM fallback")
        beam_execute(command, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Run command in a supervised BEAM Task with a timeout.
  # This replicates the original ShellExecute behaviour so disabling the sandbox
  # is a true no-op.
  @spec beam_execute(String.t(), keyword()) :: exec_result()
  defp beam_execute(command, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    cwd = Keyword.get(opts, :cwd, nil)

    task =
      Task.async(fn ->
        try do
          cmd_opts =
            [stderr_to_stdout: true]
            |> then(fn o -> if cwd, do: Keyword.put(o, :cd, cwd), else: o end)

          System.cmd("sh", ["-c", command], cmd_opts)
        rescue
          e -> {Exception.message(e), 1}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, exit_code}} ->
        {:ok, output, exit_code}

      nil ->
        Logger.warning("[Sandbox.Executor] BEAM task timed out after #{timeout}ms")
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  # Merge config-level Docker options with per-call overrides.
  # The :image key in call_opts is validated against the allowlist before use;
  # any disallowed image is rejected and the config default is used instead.
  @spec config_to_docker_opts(Config.t(), keyword()) :: keyword()
  defp config_to_docker_opts(config, call_opts) do
    requested_image = Keyword.get(call_opts, :image, config.image)

    verified_image =
      if Config.image_allowed?(config, requested_image) do
        requested_image
      else
        Logger.warning(
          "[Sandbox.Executor] Rejected disallowed image: #{requested_image}, using #{config.image}"
        )

        config.image
      end

    config_defaults = [
      timeout: config.timeout,
      network: config.network,
      max_memory: config.max_memory,
      max_cpu: config.max_cpu,
      image: verified_image
    ]

    # Strip :image from call_opts so the verified value above is used
    Keyword.merge(config_defaults, Keyword.delete(call_opts, :image))
  end
end
