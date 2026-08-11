defmodule OptimalSystemAgent.Supervisors.BootTiming do
  @moduledoc """
  Per-child start timing for the supervision tree.

  A `Supervisor` starts its children **sequentially, in the supervisor
  process**, and reports nothing about how long each one took. That is how a
  single child (`Tools.Registry`, compiling a goldrush module over 82 tool
  names) came to own ~6 of OSA's ~8 second boot while producing a completely
  silent gap in the log — invisible until someone bisected it by hand.

  `wrap/2` fixes that permanently: it rewrites each child spec's `:start` MFA
  to run through `start_child/5`, which times the call, records it, and returns
  the child's result untouched. Wrapping is transparent:

    * the MFA is still applied **in the supervisor process**, so the `link` the
      supervisor relies on is established exactly as before;
    * the return value is passed through verbatim, so `{:ok, pid}`, `:ignore`
      and `{:error, reason}` all behave identically.

  ## Reading the output

    * every child logs at `:debug` — `[BootTiming] Infrastructure/Elixir.Foo 3ms`
    * `log_summary/0` logs exactly one `:info` line per boot, naming the total
      and the slowest children with their millisecond costs
    * a child that alone exceeds one second logs a `:warning`

  So the default (`:info`) level costs one line and still carries the whole
  boot budget: a regression shows up as a changed number in the next boot log
  instead of needing to be re-bisected by hand.

  ## Storage

  Timings accumulate in the `:osa_boot_timing` ETS table, created by
  `init_table/0` from the application master (long-lived) for the same reason
  as every other table in `Application.start/2`: a lazily created named table
  is owned by whichever transient process wrote first and dies with it. When
  the table is absent (a supervisor started standalone in a unit test) timing
  degrades to a no-op — it must never be able to break a start.
  """

  require Logger

  @table :osa_boot_timing

  # A child slower than this is called out individually at :warning. Deliberately
  # set ABOVE the cost of the slowest healthy child (Tools.Registry, ~300ms) so a
  # normal boot emits no warnings at all — a warning that fires every time is a
  # warning everyone learns to skip. The per-boot `:info` summary already carries
  # the numbers needed to spot a regression; this threshold is for the case where
  # one child has gone visibly, individually wrong.
  @slow_child_ms 1_000

  # How many of the slowest children the one-line summary names.
  @summary_slowest 5

  @doc """
  Create the boot-timing table. Called once from `Application.start/2`.
  """
  @spec init_table() :: :ok
  def init_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :ordered_set])
    end

    :ok
  end

  @doc """
  Wrap a supervisor child list so each child's start is timed.

  `group` is a short label for the supervisor (e.g. `"Infrastructure"`) used in
  the log lines. Returns child specs, so the result is passed straight to
  `Supervisor.init/2`.
  """
  @spec wrap([term()], String.t()) :: [Supervisor.child_spec()]
  def wrap(children, group) when is_list(children) and is_binary(group) do
    Enum.map(children, &wrap_child(&1, group))
  end

  defp wrap_child(child, group) do
    case Supervisor.child_spec(child, []) do
      %{start: {mod, fun, args}} = spec ->
        %{spec | start: {__MODULE__, :start_child, [group, spec.id, mod, fun, args]}}

      spec ->
        spec
    end
  rescue
    # A malformed child spec must fail in the supervisor with its own error,
    # not in the instrumentation that was only meant to observe it.
    _ -> child
  end

  @doc false
  # Runs in the supervisor process, exactly where the original MFA would have.
  def start_child(group, id, mod, fun, args) do
    {micros, result} = :timer.tc(mod, fun, args)
    record(group, id, div(micros, 1000))
    result
  end

  defp record(group, id, ms) do
    label = "#{group}/#{inspect(id)}"

    Logger.debug("[BootTiming] #{label} #{ms}ms")

    if ms >= @slow_child_ms do
      Logger.warning("[BootTiming] #{label} took #{ms}ms to start (blocks boot)")
    end

    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {:erlang.unique_integer([:monotonic]), group, id, ms})
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  All recorded child timings, in start order: `{group, id, ms}`.
  """
  @spec timings() :: [{String.t(), term(), non_neg_integer()}]
  def timings do
    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_seq, group, id, ms} -> {group, id, ms} end)
    end
  rescue
    _ -> []
  end

  @doc """
  Log a one-line boot budget: total supervised start time and the slowest
  children. Called from `Application.start/2` once the tree is up.
  """
  @spec log_summary() :: :ok
  def log_summary do
    case timings() do
      [] ->
        :ok

      recorded ->
        # A subsystem supervisor's own timing already CONTAINS its children's,
        # so summing everything would count that work twice. Total over leaves
        # only; roll-ups still appear in the "slowest" list, where they are the
        # useful number (which subsystem owns the boot budget).
        {rollups, leaves} = Enum.split_with(recorded, &rollup?(&1, recorded))
        total = Enum.reduce(leaves, 0, fn {_g, _id, ms}, acc -> acc + ms end)

        slowest =
          recorded
          |> Enum.sort_by(fn {_g, _id, ms} -> -ms end)
          |> Enum.take(@summary_slowest)
          |> Enum.map_join(", ", fn {group, id, ms} -> "#{group}/#{short(id)} #{ms}ms" end)

        Logger.info(
          "[BootTiming] #{length(leaves)} children (+#{length(rollups)} subsystem) " <>
            "started in #{total}ms — slowest: #{slowest}"
        )
    end
  end

  # True when this entry is a supervisor whose own children were also timed —
  # i.e. some other entry's group is this child's short name minus the
  # "Supervisors." prefix ("Root/Supervisors.Infrastructure" ↔ group
  # "Infrastructure").
  defp rollup?({_group, id, _ms}, recorded) do
    case short(id) do
      "Supervisors." <> group -> Enum.any?(recorded, fn {g, _, _} -> g == group end)
      _ -> false
    end
  end

  # `OptimalSystemAgent.Tools.Registry` → `Tools.Registry`; anything else
  # (tuples, arbitrary terms used as child ids) falls back to inspect/1.
  defp short(id) when is_atom(id) do
    case Atom.to_string(id) do
      "Elixir.OptimalSystemAgent." <> rest -> rest
      "Elixir." <> rest -> rest
      other -> other
    end
  end

  defp short(id), do: inspect(id)
end
