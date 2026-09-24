defmodule OptimalSystemAgent.Agent.Tasks.Check do
  @moduledoc """
  Acceptance checks for plan items (`task_write` checklist entries).

  A checklist item can carry a `check` -- a command to run, a file or symbol
  that must exist, or a test that must pass. The point is the harness runs
  it, not the model: `Tracker.complete_task/3` calls `run/2` itself before it
  ever transitions a checked task to `:completed`, so "done" stops being
  whatever the model asserts and starts being whatever the check actually
  verified.

  ## Shapes

  A raw check (as the model supplies it via `task_write`, string-keyed JSON):

      %{"type" => "command", "command" => "mix test test/foo_test.exs"}
      %{"type" => "file_exists", "path" => "lib/foo.ex"}
      %{"type" => "symbol_exists", "path" => "lib/foo.ex", "symbol" => "def bar"}

  `"symbol"` is a plain substring unless wrapped in `/.../`, in which case it
  is compiled as a regex.

  A resolved check (what `Tracker` persists on the task, atom-keyed):

      %{
        type: "command" | "file_exists" | "symbol_exists",
        command: String.t() | nil,
        path: String.t() | nil,
        symbol: String.t() | nil,
        status: "pending" | "passed" | "failed",
        last_run_at: DateTime.t() | nil,
        output: String.t() | nil
      }
  """

  @types ~w(command file_exists symbol_exists)

  # A check that runs a real shell command is a synchronous, potentially slow
  # operation (a test suite). Bounded so an acceptance check can never hang
  # the GenServer call that runs it. Configurable for slow suites:
  #   config :optimal_system_agent, :task_check_timeout_ms, 300_000
  @default_timeout_ms 120_000

  # Persisted checks carry their last output for display; capped so a noisy
  # command (a full test-suite log) cannot balloon the tasks.json file.
  @max_output_chars 4_000

  @doc """
  Normalize a raw, string-keyed check spec (from `task_write` tool args) into
  the canonical atom-keyed shape, defaulted to `status: "pending"`.

  Returns `nil` for `nil`/invalid input -- absence of a check is the common
  case, not an error.
  """
  @spec normalize(map() | nil) :: map() | nil
  def normalize(nil), do: nil

  def normalize(%{"type" => type} = raw) when type in @types do
    %{
      type: type,
      command: str(raw["command"]),
      path: str(raw["path"]),
      symbol: str(raw["symbol"]),
      status: "pending",
      last_run_at: nil,
      output: nil
    }
  end

  def normalize(_invalid), do: nil

  defp str(v) when is_binary(v) and v != "", do: v
  defp str(_), do: nil

  @doc "Short human description of a check, for the checklist display."
  @spec describe(map() | nil) :: String.t() | nil
  def describe(nil), do: nil
  def describe(%{type: "command", command: cmd}), do: "command: #{cmd}"
  def describe(%{type: "file_exists", path: path}), do: "file exists: #{path}"

  def describe(%{type: "symbol_exists", path: path, symbol: symbol}),
    do: "symbol in #{path}: #{symbol}"

  def describe(_), do: "check"

  @doc """
  Run a check, returning the check map updated with the verdict.

  Executed BY THE HARNESS -- this is the whole point (an item is only marked
  done when its check passes, never when the model merely says so). Fails
  closed: any error, timeout, or unresolvable check type resolves to `"failed"`
  with the error captured in `output`.
  """
  @spec run(map(), keyword()) :: map()
  def run(check, opts \\ [])

  def run(%{type: type} = check, opts) when type in @types do
    {status, output} = do_run(check, opts)

    %{
      check
      | status: status,
        last_run_at: DateTime.utc_now(),
        output: truncate(output)
    }
  rescue
    e ->
      %{check | status: "failed", last_run_at: DateTime.utc_now(), output: Exception.message(e)}
  end

  def run(check, _opts), do: check

  defp do_run(%{type: "file_exists", path: path}, _opts) when is_binary(path) do
    if File.exists?(resolve_path(path)) do
      {"passed", "exists: #{path}"}
    else
      {"failed", "not found: #{path}"}
    end
  end

  defp do_run(%{type: "file_exists"}, _opts), do: {"failed", "no path given"}

  defp do_run(%{type: "symbol_exists", path: path, symbol: symbol}, _opts)
       when is_binary(path) and is_binary(symbol) do
    full_path = resolve_path(path)

    case File.read(full_path) do
      {:ok, contents} ->
        if symbol_present?(contents, symbol) do
          {"passed", "found #{inspect(symbol)} in #{path}"}
        else
          {"failed", "#{inspect(symbol)} not found in #{path}"}
        end

      {:error, reason} ->
        {"failed", "could not read #{path}: #{inspect(reason)}"}
    end
  end

  defp do_run(%{type: "symbol_exists"}, _opts), do: {"failed", "path and symbol required"}

  defp do_run(%{type: "command", command: command}, opts) when is_binary(command) do
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())
    run_command(command, timeout_ms)
  end

  defp do_run(%{type: "command"}, _opts), do: {"failed", "no command given"}

  defp run_command(command, timeout_ms) do
    task =
      Task.async(fn ->
        OptimalSystemAgent.OS.Shell.cmd(command, stderr_to_stdout: true, cd: resolve_path("."))
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {"passed", output}
      {:ok, {output, code}} -> {"failed", "exit #{code}\n#{output}"}
      nil -> {"failed", "timed out after #{timeout_ms}ms"}
    end
  rescue
    e -> {"failed", "command raised: #{Exception.message(e)}"}
  end

  defp symbol_present?(contents, symbol) do
    case Regex.run(~r{^/(.*)/$}, symbol) do
      [_, pattern] ->
        case Regex.compile(pattern) do
          {:ok, re} -> Regex.match?(re, contents)
          _ -> String.contains?(contents, symbol)
        end

      _ ->
        String.contains?(contents, symbol)
    end
  end

  defp resolve_path(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(workspace_dir(), path)
    end
  end

  defp workspace_dir do
    OptimalSystemAgent.Workspace.Cwd.get()
  rescue
    _ -> File.cwd!()
  end

  defp default_timeout_ms do
    Application.get_env(:optimal_system_agent, :task_check_timeout_ms, @default_timeout_ms)
  end

  defp truncate(output) when is_binary(output) do
    if String.length(output) > @max_output_chars do
      String.slice(output, 0, @max_output_chars) <> "... [truncated]"
    else
      output
    end
  end

  defp truncate(output), do: inspect(output) |> truncate()

  @doc "Serialize a resolved check map to string keys for JSON persistence."
  @spec serialize(map() | nil) :: map() | nil
  def serialize(nil), do: nil

  def serialize(%{} = check) do
    %{
      "type" => Map.get(check, :type),
      "command" => Map.get(check, :command),
      "path" => Map.get(check, :path),
      "symbol" => Map.get(check, :symbol),
      "status" => Map.get(check, :status, "pending"),
      "last_run_at" =>
        case Map.get(check, :last_run_at) do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          _ -> nil
        end,
      "output" => Map.get(check, :output)
    }
  end

  @doc "Deserialize a persisted (string-keyed) check map back to atom keys."
  @spec deserialize(map() | nil) :: map() | nil
  def deserialize(nil), do: nil

  def deserialize(%{} = map) do
    %{
      type: map["type"],
      command: map["command"],
      path: map["path"],
      symbol: map["symbol"],
      status: map["status"] || "pending",
      last_run_at: parse_datetime(map["last_run_at"]),
      output: map["output"]
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
