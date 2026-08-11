# Goldrush (:glc) characterisation benchmark.
#
# Run:
#   PATH="$HOME/.asdf/installs/elixir/1.19.5-otp-28/bin:$HOME/.asdf/installs/erlang/28.3/bin:$PATH" \
#   elixir -pa _build/dev/lib/goldrush/ebin bench/goldrush_bench.exs
#
# Measures, with no OSA code loaded:
#   A. :glc.compile/2 wall cost vs number of :glc.any/1 branches
#   B. per-event :glc.handle/2 cost vs the obvious plain-BEAM alternatives
#   C. what the generated module actually does per event (decompiled)

{:ok, _} = Application.ensure_all_started(:goldrush)

defmodule Bench do
  # median of `runs` timed passes of `n` iterations, returns ns/op
  def ns_per_op(fun, n, runs \\ 7) do
    for _ <- 1..runs do
      {us, _} = :timer.tc(fn -> loop(fun, n) end)
      us * 1000 / n
    end
    |> Enum.sort()
    |> Enum.at(div(runs, 2))
  end

  defp loop(_fun, 0), do: :ok
  defp loop(fun, n), do: (fun.(); loop(fun, n - 1))

  def ms(fun) do
    {us, r} = :timer.tc(fun)
    {us / 1000, r}
  end
end

types = ~w(user_message llm_request llm_response tool_call tool_result tool_render
           agent_response system_event channel_connected channel_disconnected
           channel_error ask_user_question survey_answered algedonic_alert
           signal_classified doom_loop_halt auto_mode_blocked auto_mode_paused)a

IO.puts("\n================ A. COMPILE COST vs BRANCH COUNT ================")
IO.puts("branches |  compile ms")

for n <- [1, 2, 4, 8, 12, 16, 18, 20, 24, 32, 40, 60, 82] do
  names = for i <- 1..n, do: :"branch_#{i}"
  filters = Enum.map(names, &:glc.eq(:type, &1))
  q = :glc.with(:glc.any(filters), fn _e -> :ok end)
  mod = :"bench_compile_#{n}"
  {ms, _} = Bench.ms(fn -> :glc.compile(mod, q) end)
  IO.puts(String.pad_leading("#{n}", 8) <> " | " <> :erlang.float_to_binary(ms, decimals: 1))
end

IO.puts("\n================ B. PER-EVENT DISPATCH COST ================")

# The exact shape OSA's Events.Bus compiles: any([eq(:type, t) || t <- 18 types])
filters = Enum.map(types, &:glc.eq(:type, &1))

:ets.new(:bench_handlers, [:named_table, :public, :bag])
Enum.each(types, fn t -> :ets.insert(:bench_handlers, {t, make_ref(), fn _ -> :ok end}) end)

counter = :counters.new(1, [:write_concurrency])
sink = fn _payload -> :counters.add(counter, 1, 1) end

# 1. goldrush, handler does an ETS handler lookup then calls each handler (== Bus.dispatch_event)
q_full =
  :glc.with(:glc.any(filters), fn ev ->
    t = :gre.fetch(:type, ev)
    payload = ev |> :gre.pairs() |> Map.new()
    :ets.lookup(:bench_handlers, t) |> Enum.each(fn {_, _r, h} -> h.(payload) end)
    sink.(payload)
  end)

{:ok, _} = :glc.compile(:bench_router_full, q_full)

# 2. goldrush, empty handler — isolates pure match cost
q_bare = :glc.with(:glc.any(filters), fn _ev -> :ok end)
{:ok, _} = :glc.compile(:bench_router_bare, q_bare)

# A representative OSA event: 14 fields (Event.to_map + timestamp)
fields = [
  type: :tool_result,
  id: "0195c0de-1111-4222-8333-444455556666",
  source: "bus",
  time: 1_770_000_000,
  timestamp: System.monotonic_time(),
  payload: %{tool: "read_file", ok: true},
  parent_id: nil,
  session_id: "sess-1",
  correlation_id: "corr-1",
  signal_mode: :operational,
  signal_genre: :report,
  signal_sn: 0.9,
  metadata: %{},
  version: 1
]

n = 200_000

gre_ev = :gre.make(fields, [:list])
map_ev = Map.new(fields)

# --- goldrush variants
t_glc_bare = Bench.ns_per_op(fn -> :glc.handle(:bench_router_bare, gre_ev) end, n)
t_glc_full = Bench.ns_per_op(fn -> :glc.handle(:bench_router_full, gre_ev) end, n)
# include the :gre.make/2 the Bus pays on every emit
t_glc_make = Bench.ns_per_op(fn -> :glc.handle(:bench_router_full, :gre.make(fields, [:list])) end, n)

# --- plain-BEAM alternatives, same observable work as q_full
type_set = MapSet.new(types)
handler_map = Map.new(types, fn t -> {t, [fn _ -> :ok end]} end)

# (a) guard membership (what `def emit(t, ...) when t in @event_types` already compiles to)
defmodule Guard do
  @types ~w(user_message llm_request llm_response tool_call tool_result tool_render
            agent_response system_event channel_connected channel_disconnected
            channel_error ask_user_question survey_answered algedonic_alert
            signal_classified doom_loop_halt auto_mode_blocked auto_mode_paused)a
  def known?(t) when t in @types, do: true
  def known?(_), do: false
end

f_case = fn ev ->
  t = ev.type
  if Guard.known?(t) do
    :ets.lookup(:bench_handlers, t) |> Enum.each(fn {_, _r, h} -> h.(ev) end)
    sink.(ev)
  end
end

f_mapset = fn ev ->
  t = ev.type
  if MapSet.member?(type_set, t) do
    :ets.lookup(:bench_handlers, t) |> Enum.each(fn {_, _r, h} -> h.(ev) end)
    sink.(ev)
  end
end

f_maplookup = fn ev ->
  case Map.fetch(handler_map, ev.type) do
    {:ok, hs} -> Enum.each(hs, fn h -> h.(ev) end); sink.(ev)
    :error -> :ok
  end
end

# (d) ETS only — no membership test at all; a miss is just an empty list
f_ets_only = fn ev ->
  case :ets.lookup(:bench_handlers, ev.type) do
    [] -> :ok
    hs -> Enum.each(hs, fn {_, _r, h} -> h.(ev) end); sink.(ev)
  end
end

# (e) ETS select with a match_spec (the "compiled matcher" alternative)
ms = [{{:"$1", :_, :"$3"}, [{:==, :"$1", :tool_result}], [:"$3"]}]
f_ets_ms = fn ev -> _ = :ets.select(:bench_handlers, ms); sink.(ev) end

t_case = Bench.ns_per_op(fn -> f_case.(map_ev) end, n)
t_mapset = Bench.ns_per_op(fn -> f_mapset.(map_ev) end, n)
t_map = Bench.ns_per_op(fn -> f_maplookup.(map_ev) end, n)
t_ets = Bench.ns_per_op(fn -> f_ets_only.(map_ev) end, n)
t_ms = Bench.ns_per_op(fn -> f_ets_ms.(map_ev) end, n)

rows = [
  {"goldrush handle (no-op handler, pre-made gre event)", t_glc_bare},
  {"goldrush handle (Bus-equivalent handler)", t_glc_full},
  {"goldrush handle + :gre.make/2 (what Bus.emit really pays)", t_glc_make},
  {"plain: `type in @types` guard + ETS lookup + call", t_case},
  {"plain: MapSet.member? + ETS lookup + call", t_mapset},
  {"plain: Map.fetch handler map + call", t_map},
  {"plain: ETS lookup only (miss == [])", t_ets},
  {"plain: ETS select/match_spec", t_ms}
]

IO.puts("")
Enum.each(rows, fn {label, v} ->
  IO.puts(String.pad_trailing(label, 60) <> String.pad_leading(:erlang.float_to_binary(v, decimals: 0), 8) <> " ns/op")
end)

IO.puts("\nfastest plain alternative vs goldrush(full): " <>
  :erlang.float_to_binary(t_glc_full / Enum.min([t_case, t_mapset, t_map, t_ets]), decimals: 2) <> "x")

IO.puts("\n================ B2. NON-MATCHING EVENT (filter rejects) ================")
miss = [type: :not_a_real_type, id: "x", payload: %{}]
miss_gre = :gre.make(miss, [:list])
miss_map = Map.new(miss)
IO.puts("goldrush handle (reject)     : #{Bench.ns_per_op(fn -> :glc.handle(:bench_router_bare, miss_gre) end, n) |> :erlang.float_to_binary(decimals: 0)} ns/op")
IO.puts("plain guard      (reject)    : #{Bench.ns_per_op(fn -> f_case.(miss_map) end, n) |> :erlang.float_to_binary(decimals: 0)} ns/op")

IO.puts("\n================ C. WHAT THE GENERATED MODULE DOES ================")
IO.inspect(:bench_router_bare.module_info(:exports), label: "exports")
IO.puts("counters after the runs above (ETS update_counter is done per event, per stage):")
for k <- [:input, :filter, :output] do
  IO.inspect(:bench_router_bare.info(k), label: to_string(k))
end

IO.puts("\n---- optimized query tree (glc_lib:reduce output) ----")
IO.inspect(:bench_router_bare.explain(), limit: :infinity, printable_limit: :infinity)

IO.puts("\n================ D. MATCH COST vs BRANCH COUNT ================")
IO.puts("(is the compiled matcher O(1) or O(branches)? first branch vs last branch)")
IO.puts("branches | first-type ns/op | last-type ns/op | miss ns/op")

for b <- [2, 8, 18, 40, 82] do
  names = for i <- 1..b, do: :"t_#{i}"
  fs = Enum.map(names, &:glc.eq(:type, &1))
  mod = :"bench_match_#{b}"
  {:ok, _} = :glc.compile(mod, :glc.with(:glc.any(fs), fn _ -> :ok end))
  first = :gre.make([type: :t_1, id: "x"], [:list])
  last = :gre.make([type: :"t_#{b}", id: "x"], [:list])
  none = :gre.make([type: :nope, id: "x"], [:list])
  f = Bench.ns_per_op(fn -> :glc.handle(mod, first) end, 50_000, 5)
  l = Bench.ns_per_op(fn -> :glc.handle(mod, last) end, 50_000, 5)
  m = Bench.ns_per_op(fn -> :glc.handle(mod, none) end, 50_000, 5)
  IO.puts(
    String.pad_leading("#{b}", 8) <> " | " <>
    String.pad_leading(:erlang.float_to_binary(f, decimals: 0), 16) <> " | " <>
    String.pad_leading(:erlang.float_to_binary(l, decimals: 0), 15) <> " | " <>
    String.pad_leading(:erlang.float_to_binary(m, decimals: 0), 10))
end

IO.puts("\n================ E. WHERE THE 4.5us GOES ================")
# statistics:false removes the per-event ETS counter updates
fs2 = Enum.map(types, &:glc.eq(:type, &1))
{:ok, _} = :glc.compile(:bench_nostats, :glc.with(:glc.any(fs2), fn _ -> :ok end), [{:statistics, false}], false)
IO.puts("goldrush handle, statistics:false : #{Bench.ns_per_op(fn -> :glc.handle(:bench_nostats, gre_ev) end, n) |> :erlang.float_to_binary(decimals: 0)} ns/op")
IO.puts("goldrush handle, statistics:true  : #{:erlang.float_to_binary(t_glc_bare, decimals: 0)} ns/op   (OSA uses the default => true)")
IO.puts(":gre.make/2 alone                 : #{Bench.ns_per_op(fn -> :gre.make(fields, [:list]) end, n) |> :erlang.float_to_binary(decimals: 0)} ns/op")
IO.puts(":gre.fetch/2 alone                : #{Bench.ns_per_op(fn -> :gre.fetch(:type, gre_ev) end, n) |> :erlang.float_to_binary(decimals: 0)} ns/op")
IO.puts(":gre.pairs/1 |> Map.new           : #{Bench.ns_per_op(fn -> gre_ev |> :gre.pairs() |> Map.new() end, n) |> :erlang.float_to_binary(decimals: 0)} ns/op")

IO.puts("\n================ F. Task.Supervisor.start_child overhead ================")
{:ok, sup} = Task.Supervisor.start_link()
IO.puts("Task.Supervisor.start_child (Bus does 2 per emit + 1 per handler):")
IO.puts("  #{Bench.ns_per_op(fn -> Task.Supervisor.start_child(sup, fn -> :ok end) end, 20_000, 5) |> :erlang.float_to_binary(decimals: 0)} ns/op")
