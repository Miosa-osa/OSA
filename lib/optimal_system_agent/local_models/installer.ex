defmodule OptimalSystemAgent.LocalModels.Installer do
  @moduledoc """
  Background install jobs for `LocalModels` with pollable progress — the
  HTTP/TUI side of `/models install`.

  A pull takes minutes; an HTTP request cannot. `start/2` kicks off
  `LocalModels.install/2` in a task and returns a job id; `status/1` reports
  where it is (`:pulling` with bytes, `:benchmarking`, `:done` with the
  measured speed, or `:error`). Jobs live in a public ETS table created on
  first use, so nothing in the supervision tree needs to know about them.
  One job per tag at a time.
  """

  alias OptimalSystemAgent.LocalModels

  @table :osa_local_model_jobs

  @type status :: %{
          id: String.t(),
          ref: String.t(),
          tag: String.t() | nil,
          state: :pulling | :benchmarking | :done | :error,
          status: String.t(),
          completed: non_neg_integer(),
          total: non_neg_integer(),
          bench: map() | nil,
          error: String.t() | nil,
          started_at: integer(),
          updated_at: integer()
        }

  @doc """
  Start pulling `ref` (catalog id / hf.co tag / Ollama tag) at `quant`.
  `run: false` (tests) records the job without spawning the task.
  """
  @spec start(String.t(), String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def start(ref, quant \\ nil, opts \\ []) when is_binary(ref) do
    ensure_table()

    if Enum.any?(list(), &(&1.ref == ref and &1.state in [:pulling, :benchmarking])) do
      {:error, "already installing #{ref}"}
    else
      id = "job-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      now = System.system_time(:millisecond)

      put(%{
        id: id,
        ref: ref,
        tag: nil,
        state: :pulling,
        status: "starting",
        completed: 0,
        total: 0,
        bench: nil,
        error: nil,
        started_at: now,
        updated_at: now
      })

      if Keyword.get(opts, :run, true), do: Task.start(fn -> run(id, ref, quant) end)
      {:ok, id}
    end
  end

  @doc "Current state of a job, or nil."
  @spec status(String.t()) :: status() | nil
  def status(id) when is_binary(id) do
    ensure_table()

    case :ets.lookup(@table, id) do
      [{^id, job}] -> job
      _ -> nil
    end
  end

  @doc "Every job this node has seen (finished ones stay until `forget/1`)."
  @spec list() :: [status()]
  def list do
    ensure_table()
    @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.started_at, :desc)
  end

  @spec forget(String.t()) :: :ok
  def forget(id) do
    ensure_table()
    :ets.delete(@table, id)
    :ok
  end

  # Test seam: run the job body synchronously with an injectable installer.
  @doc false
  def run(id, ref, quant, install_fun \\ &LocalModels.install/2) do
    on_progress = fn %{status: status, completed: c, total: t} ->
      update(id, fn job ->
        state = if status == "success", do: :benchmarking, else: :pulling
        %{job | state: state, status: status, completed: c, total: t}
      end)
    end

    case install_fun.(ref, on_progress: on_progress, quant: quant) do
      {:ok, %{tag: tag, bench: bench}} ->
        update(id, &%{&1 | state: :done, status: "done", tag: tag, bench: bench})

      {:error, reason} ->
        update(id, &%{&1 | state: :error, status: "failed", error: to_string(reason)})
    end
  rescue
    e -> update(id, &%{&1 | state: :error, status: "failed", error: Exception.message(e)})
  end

  defp update(id, fun) do
    case status(id) do
      nil -> :ok
      job -> put(fun.(%{job | updated_at: System.system_time(:millisecond)}))
    end
  end

  defp put(job), do: :ets.insert(@table, {job.id, job})

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end
end
