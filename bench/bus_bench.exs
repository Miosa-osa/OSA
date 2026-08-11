# End-to-end OptimalSystemAgent.Events.Bus measurement, against the real app.
#
# Run:
#   MIX_HOME=/home/miosa/.asdf/installs/elixir/1.19.5-otp-28/.mix \
#   PATH="$HOME/.asdf/installs/elixir/1.19.5-otp-28/bin:$HOME/.asdf/installs/erlang/28.3/bin:$PATH" \
#   OSA_HTTP_PORT=20871 MIX_ENV=test mix run bench/bus_bench.exs
#
# Answers: what does one Bus.emit actually cost end-to-end, how much of that is
# goldrush, and how does the goldrush router compare to a direct ETS dispatch
# doing exactly the same observable work.

alias OptimalSystemAgent.Events.Bus

defmodule B do
  def ns(fun, n, runs \\ 5) do
    for _ <- 1..runs do
      {us, _} = :timer.tc(fn -> loop(fun, n) end)
      us * 1000 / n
    end
    |> Enum.sort()
    |> Enum.at(div(runs, 2))
  end

  defp loop(_f, 0), do: :ok
  defp loop(f, n), do: (f.(); loop(f, n - 1))
end

# Wait for the Bus + its compiled router.
Process.sleep(500)
Logger.configure(level: :error)
true = is_pid(Process.whereis(Bus))
IO.puts("router module loaded? #{inspect(Code.ensure_loaded?(:osa_event_router))}")

counter = :counters.new(1, [:write_concurrency])
ref = Bus.register_handler(:system_event, fn _p -> :counters.add(counter, 1, 1) end)

payload = %{event: :tool_progress, tool: "read_file", session_id: "bench", pct: 50}

IO.puts("\n== how many handlers are registered right now (a live OSA process tree) ==")
:ets.tab2list(:osa_event_handlers)
|> Enum.group_by(fn t -> elem(t, 0) end)
|> Enum.map(fn {k, v} -> {k, length(v)} end)
|> Enum.sort()
|> IO.inspect(label: "handlers per type")

n = 20_000

IO.puts("\n== full Bus.emit/3 (2 Task.Supervisor spawns + classify + goldrush) ==")
t_emit = B.ns(fn -> Bus.emit(:system_event, payload, source: "bench") end, n)
IO.puts("  #{:erlang.float_to_binary(t_emit, decimals: 0)} ns/op (caller-side; work is async)")

Process.sleep(2000)
IO.puts("  handler invocations observed: #{:counters.get(counter, 1)}")

IO.puts("\n== the goldrush hop in isolation, exactly as Bus does it ==")
ev = OptimalSystemAgent.Events.Event.new(:system_event, "bench", payload, [])

gre_fields =
  ev
  |> OptimalSystemAgent.Events.Event.to_map()
  |> Map.put(:timestamp, System.monotonic_time())
  |> Map.to_list()

gre_ev = :gre.make(gre_fields, [:list])

t_glc = B.ns(fn -> :glc.handle(:osa_event_router, gre_ev) end, 5_000)
IO.puts("  :glc.handle(:osa_event_router, ev)          #{:erlang.float_to_binary(t_glc, decimals: 0)} ns/op")

# The observably-identical replacement: type guard + ETS lookup + the SAME
# dispatch_with_dlq tail (Task.Supervisor.start_child per handler), so the only
# difference measured is goldrush's filter/gre layer, not the handler spawn.
map_payload = Map.new(gre_fields)

spawn_handler = fn h, p ->
  Task.Supervisor.start_child(OptimalSystemAgent.Events.TaskSupervisor, fn -> h.(p) end)
end

direct = fn p ->
  t = p.type

  if t in Bus.event_types() do
    :ets.lookup(:osa_event_handlers, t)
    |> Enum.each(fn
      {_, _r, h} -> spawn_handler.(h, p)
      {_, h} -> spawn_handler.(h, p)
    end)
  end
end

t_direct = B.ns(fn -> direct.(map_payload) end, 5_000)
IO.puts("  direct: `t in event_types` + ETS + dispatch  #{:erlang.float_to_binary(t_direct, decimals: 0)} ns/op")
IO.puts("  goldrush is #{:erlang.float_to_binary(t_glc / t_direct, decimals: 1)}x the cost of the direct path")

IO.puts("\n== Event.new + Classifier.auto_classify (the rest of do_emit) ==")
t_new = B.ns(fn -> OptimalSystemAgent.Events.Event.new(:system_event, "bench", payload, []) end, 20_000)
t_cls = B.ns(fn -> OptimalSystemAgent.Events.Classifier.auto_classify(ev) end, 20_000)
IO.puts("  Event.new/4                #{:erlang.float_to_binary(t_new, decimals: 0)} ns/op")
IO.puts("  Classifier.auto_classify/1 #{:erlang.float_to_binary(t_cls, decimals: 0)} ns/op")

IO.puts("\n== goldrush share of the whole emit pipeline ==")
whole = t_new + t_cls + t_glc
IO.puts("  Event.new + classify + goldrush = #{:erlang.float_to_binary(whole, decimals: 0)} ns")
IO.puts("  goldrush share: #{:erlang.float_to_binary(t_glc / whole * 100, decimals: 1)}%")
IO.puts("  savings if replaced by the direct path: #{:erlang.float_to_binary((t_glc - t_direct) / 1000, decimals: 2)} us/event")

Bus.unregister_handler(:system_event, ref)
