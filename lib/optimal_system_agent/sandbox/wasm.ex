defmodule OptimalSystemAgent.Sandbox.Wasm do
  @moduledoc """
  WebAssembly sandbox backend via wasmtime CLI.

  Mirrors the Sandbox.Docker interface for consistent execution semantics.
  Uses `wasmtime run` with restricted filesystem access and computation limits.
  """

  require Logger

  @default_timeout 30_000
  @default_fuel 1_000_000_000

  @doc "Check if wasmtime is available on the system."
  @spec available?() :: boolean()
  def available? do
    System.find_executable("wasmtime") != nil
  end

  @doc """
  Execute a WASM module via wasmtime.

  ## Options
  - `:timeout` — execution timeout in ms (default 30_000)
  - `:fuel` — computation fuel limit (default 1_000_000_000)
  - `:workspace` — host directory to mount as /workspace
  - `:wasm_file` — path to .wasm file to execute
  - `:args` — additional arguments to pass
  - `:env` — environment variables as [{key, value}]
  """
  @spec execute(String.t(), keyword()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, String.t()}
  def execute(command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    fuel = Keyword.get(opts, :fuel, @default_fuel)
    workspace = Keyword.get(opts, :workspace)
    wasm_file = Keyword.get(opts, :wasm_file)
    extra_args = Keyword.get(opts, :args, [])
    env_vars = Keyword.get(opts, :env, [])

    args = build_args(command, fuel, workspace, wasm_file, extra_args, env_vars)

    Logger.debug("[Sandbox.Wasm] Executing: wasmtime #{Enum.join(args, " ")}")

    task =
      Task.async(fn ->
        try do
          System.cmd("wasmtime", args, stderr_to_stdout: true)
        rescue
          e -> {Exception.message(e), 1}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, exit_code}} ->
        {:ok, output, exit_code}

      nil ->
        Logger.warning("[Sandbox.Wasm] Execution timed out after #{timeout}ms")
        {:error, "WASM execution timed out after #{timeout}ms"}
    end
  end

  defp build_args(command, fuel, workspace, wasm_file, extra_args, env_vars) do
    args = ["run"]

    # Computation fuel limit
    args = args ++ ["--wasm-fuel", to_string(fuel)]

    # Filesystem: only mount workspace if specified
    args =
      if workspace do
        args ++ ["--dir", "#{workspace}::/workspace"]
      else
        args
      end

    # Environment variables
    args =
      Enum.reduce(env_vars, args, fn {key, value}, acc ->
        acc ++ ["--env", "#{key}=#{value}"]
      end)

    # WASM file or command
    args =
      if wasm_file do
        args ++ [wasm_file] ++ extra_args
      else
        # If no wasm_file, try to interpret command as a wasm path
        args ++ [command] ++ extra_args
      end

    args
  end
end
