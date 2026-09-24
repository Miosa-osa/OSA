defmodule OptimalSystemAgent.Bench do
  @moduledoc """
  OSA's own efficiency benchmark: a fixed set of small, reproducible coding
  tasks modeled on real failure modes, each scored on wall time, model time,
  tool time, tokens, cost, tool calls, retries, wasted steps and a
  deterministic pass/fail check.

  It exists so a change to the agent (routing, context handling, prompts,
  prefetch, ...) can be shown to help: run it before, run it after, compare.
  It is NOT a capability benchmark; for that see the external suites in
  `bench/README.md`.

  Entry point for the CLI is `mix osa.bench`; this module is the API the task
  and the tests share.
  """

  alias OptimalSystemAgent.Bench.{Report, Runner, TaskSpec}

  @doc "Default location of the task files and fixtures, relative to the repo."
  @spec default_root() :: Path.t()
  def default_root, do: Path.join(File.cwd!(), "bench/osabench")

  @doc """
  Run the selected tasks and return the result document (not yet written).

  Options: everything `Runner.run/2` takes, plus `:root` (tasks + fixtures),
  `:only` / `:categories` (filters), `:repeat` (attempts per task) and
  `:on_result` (a 1-arity callback per finished row, for progress output).
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(opts) do
    root = Keyword.get(opts, :root, default_root())

    with {:ok, tasks} <- TaskSpec.load_dir(Path.join(root, "tasks")) do
      tasks =
        TaskSpec.filter(tasks, Keyword.get(opts, :only, []), Keyword.get(opts, :categories, []))

      if tasks == [] do
        {:error, "no task matched the filters"}
      else
        {:ok, run_tasks(tasks, root, opts)}
      end
    end
  end

  defp run_tasks(tasks, root, opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &run_id/0)

    work_root =
      Keyword.get_lazy(opts, :work_root, fn ->
        Path.join(System.tmp_dir!(), "osa-bench-#{run_id}")
      end)

    repeat = max(Keyword.get(opts, :repeat, 1), 1)
    on_result = Keyword.get(opts, :on_result, fn _ -> :ok end)
    started_at = DateTime.utc_now()

    runner_opts =
      opts
      |> Keyword.put(:fixtures_dir, Path.join(root, "fixtures"))
      |> Keyword.put(:work_root, work_root)

    rows =
      for task <- tasks, attempt <- 1..repeat do
        row = Runner.run(task, Keyword.put(runner_opts, :attempt, attempt))
        on_result.(row)
        row
      end

    unless Keyword.get(opts, :keep_workspace, false), do: File.rm_rf(work_root)

    meta = %{
      run_id: run_id,
      started_at: DateTime.to_iso8601(started_at),
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      osa_version: osa_version(),
      git_sha: git_sha(),
      runner: to_string(Keyword.get(opts, :runner, :in_process)),
      url: Keyword.get(opts, :url),
      provider: opts |> Keyword.get(:provider) |> configured(:provider),
      model: opts |> Keyword.get(:model) |> configured(:model),
      control: opts |> Keyword.get(:control) |> then(&(&1 && to_string(&1))),
      repeat: repeat
    }

    Report.document(meta, rows)
  end

  defp run_id do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    "#{stamp}-#{:crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)}"
  end

  # What actually served the run when no override was given, so a result file
  # always says which model produced it.
  defp configured(nil, :provider) do
    OptimalSystemAgent.Providers.Registry.resolved_default_provider() |> to_string()
  rescue
    _ -> nil
  end

  defp configured(nil, :model) do
    OptimalSystemAgent.Providers.Registry.resolved_default_model() |> then(&(&1 && to_string(&1)))
  rescue
    _ -> nil
  end

  defp configured(value, _), do: to_string(value)

  defp osa_version do
    case :application.get_key(:optimal_system_agent, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> nil
    end
  end

  defp git_sha do
    case OptimalSystemAgent.Git.cmd(["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} ->
        dirty =
          case OptimalSystemAgent.Git.cmd(["status", "--porcelain", "--untracked-files=no"]) do
            {"", 0} -> ""
            _ -> "-dirty"
          end

        String.trim(sha) <> dirty

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
