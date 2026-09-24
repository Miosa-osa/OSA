defmodule OptimalSystemAgent.Bench.TaskSpec do
  @moduledoc """
  One benchmark task: a setup, a prompt and a deterministic checker.

  Tasks live one per file under `bench/osabench/tasks/*.exs`. Each file
  evaluates to a plain map (data only, no functions) so a task can be read,
  diffed and reviewed like a fixture:

      %{
        id: "settings-one-line",
        title: "One-line settings change",
        category: "edit",
        failure_mode: "what real failure this task is modeled on",
        prompt: "Set max_retries to 5 in config/settings.json.",
        setup: [...],        # ops applied to a fresh copy of the fixture repo
        check: [...],        # every op must pass for the task to pass
        reference: [...]     # the known-good tool sequence (the oracle)
      }

  See `OptimalSystemAgent.Bench.Workspace` for setup ops,
  `OptimalSystemAgent.Bench.Check` for check ops, and
  `OptimalSystemAgent.Bench.Script` for the reference format.
  """

  @enforce_keys [:id, :prompt, :check]
  defstruct id: nil,
            title: nil,
            category: "misc",
            failure_mode: nil,
            prompt: nil,
            fixture: "acme",
            setup: [],
            check: [],
            reference: [],
            timeout_s: nil,
            file: nil

  @type t :: %__MODULE__{}

  @doc "Load every `*.exs` task under `dir`, sorted by id."
  @spec load_dir(Path.t()) :: {:ok, [t()]} | {:error, String.t()}
  def load_dir(dir) do
    files = dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort()

    if files == [] do
      {:error, "no task files found in #{dir}"}
    else
      files
      |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
        case load_file(file) do
          {:ok, task} -> {:cont, {:ok, [task | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, tasks} -> check_unique(Enum.sort_by(tasks, & &1.id))
        error -> error
      end
    end
  end

  @doc "Load and validate one task file."
  @spec load_file(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load_file(file) do
    {value, _binding} = Code.eval_file(file)
    from_map(value, file)
  rescue
    e -> {:error, "#{file}: #{Exception.message(e)}"}
  end

  @doc "Build a task from its map form, validating the required fields."
  @spec from_map(map(), Path.t() | nil) :: {:ok, t()} | {:error, String.t()}
  def from_map(map, file \\ nil)

  def from_map(%{} = map, file) do
    where = file || inspect(Map.get(map, :id))

    cond do
      not (is_binary(map[:id]) and map[:id] =~ ~r/^[a-z0-9][a-z0-9-]*$/) ->
        {:error, "#{where}: :id must be a lowercase-dashed string"}

      not (is_binary(map[:prompt]) and String.trim(map[:prompt]) != "") ->
        {:error, "#{where}: :prompt is required"}

      not (is_list(map[:check]) and map[:check] != []) ->
        {:error, "#{where}: :check must be a non-empty list"}

      not is_list(Map.get(map, :setup, [])) ->
        {:error, "#{where}: :setup must be a list"}

      not is_list(Map.get(map, :reference, [])) ->
        {:error, "#{where}: :reference must be a list"}

      true ->
        {:ok, struct(__MODULE__, Map.put(map, :file, file))}
    end
  end

  def from_map(_, file), do: {:error, "#{file}: a task file must evaluate to a map"}

  defp check_unique(tasks) do
    case tasks |> Enum.frequencies_by(& &1.id) |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> {:ok, tasks}
      {id, _} -> {:error, "duplicate task id #{id}"}
    end
  end

  @doc """
  Keep the tasks named in `only` (ids) and/or in `categories`. Empty filters
  keep everything.
  """
  @spec filter([t()], [String.t()], [String.t()]) :: [t()]
  def filter(tasks, only, categories) do
    tasks
    |> Enum.filter(fn t -> only == [] or t.id in only end)
    |> Enum.filter(fn t -> categories == [] or t.category in categories end)
  end

  @doc "Number of tool calls in the reference solution (the task's par)."
  @spec par_tool_calls(t()) :: non_neg_integer()
  def par_tool_calls(%__MODULE__{reference: steps}) do
    Enum.reduce(steps, 0, fn
      calls, acc when is_list(calls) -> acc + length(calls)
      _, acc -> acc
    end)
  end
end
