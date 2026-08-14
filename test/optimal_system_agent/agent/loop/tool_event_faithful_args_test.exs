defmodule OptimalSystemAgent.Agent.Loop.ToolEventFaithfulArgsTest do
  @moduledoc """
  The `tool_call` event must carry a FAITHFUL argument representation on both
  phases, not only the TUI display hint.

  `args` is `Loop.ToolHint.summarize/1`, which is lossy on purpose: a file tool
  is reduced to its bare path (`ToolHint` :79-82) and a shell command is clipped
  to 60 characters (:85). For a long time that was the only argument-shaped
  field on the event, and two published head-to-head numbers were computed from
  it as though it were the arguments:

    * "OSA's median tool-call argument is 62 bytes" — the median was 62 because
      the log clipped at 60.
    * "43.5% duplicate tool calls" — hashing the hint collapses calls that
      differ only in a dropped field. 49 `file_read` calls reading 49 different
      offset windows of one file hash identically once `offset`/`limit` are
      gone. Re-measured against real arguments the figure is 9.4%, and none of
      them is a `file_read`.

  `Loop.ToolArgMetrics` supplies `args_bytes` and `args_hash`. This test pins
  that they actually reach the wire — on `:start` AND on `:end`.

  The `:end` phase matters separately: it is the only phase carrying `success`
  and `duration_ms`, so any analysis of *completed* calls reads it, and without
  the pair there it would be pushed straight back onto the hint.

  Both fields are a digest, never the argument text. Tool arguments routinely
  contain file contents and can contain credentials; a byte count plus a
  truncated SHA-256 answers "how big" and "is this the same call" without
  persisting anything sensitive to the event log.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolArgMetrics
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Agent.Loop.ToolHint
  alias OptimalSystemAgent.Tools.Registry

  @registry_key {Registry, :builtin_tools}

  defmodule EchoTool do
    @moduledoc false
    def name, do: "test_faithful_args_tool"
    def description, do: "accepts anything, succeeds"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args), do: {:ok, "ok"}
  end

  @stubs %{"test_faithful_args_tool" => EchoTool}

  setup do
    prev = :persistent_term.get(@registry_key, :__absent__)
    existing = if prev == :__absent__, do: %{}, else: prev
    :persistent_term.put(@registry_key, Map.merge(existing, @stubs))

    on_exit(fn ->
      case prev do
        :__absent__ -> :persistent_term.erase(@registry_key)
        value -> :persistent_term.put(@registry_key, value)
      end
    end)

    :ok
  end

  defp state(session_id) do
    %{
      session_id: session_id,
      turn_count: 0,
      iteration: 0,
      permission_tier: :full,
      permission_mode: :overdrive,
      messages: [],
      recent_failure_signatures: []
    }
  end

  # Unique across BEAM RUNS, not just within one: `durable_log_dir` is a shared
  # /tmp directory in the test env and `System.unique_integer/1` restarts low on
  # every `mix test`, so a counter-only id collides with a previous run's
  # recorded step and `DurableLog` replays it — returning the recorded result
  # without re-executing and WITHOUT emitting any tool_call event.
  defp fresh_session do
    "faithful-args-#{System.unique_integer([:positive, :monotonic])}-" <>
      (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  # Run one call and return `%{start: event, end: event}` as broadcast on the
  # session topic — the same frames the SSE stream (and therefore
  # `osa-events.jsonl`) is built from.
  defp events_for(arguments) do
    session_id = fresh_session()
    on_exit(fn -> OptimalSystemAgent.Agent.Loop.DurableLog.clear(session_id) end)
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    call = %{
      id: "tc-#{System.unique_integer([:positive, :monotonic])}",
      name: "test_faithful_args_tool",
      arguments: arguments
    }

    ToolExecutor.execute_tool_call(call, state(session_id))

    %{start: collect(:start), end: collect(:end)}
  end

  defp collect(phase) do
    want = to_string(phase)

    receive do
      {:osa_event, %{type: :tool_call, phase: ^want} = ev} -> ev
      _other -> collect(phase)
    after
      2_000 -> nil
    end
  end

  # A read of one window of a file. The hint keeps ONLY the path.
  defp read_window(offset, limit),
    do: %{"path" => "/tmp/growing.log", "offset" => offset, "limit" => limit}

  describe "the faithful pair reaches the wire" do
    test "the :start event carries args_bytes and args_hash" do
      ev = events_for(read_window(1, 100)).start

      assert ev, "no tool_call :start event was broadcast"
      assert is_integer(ev.args_bytes) and ev.args_bytes > 0
      assert is_binary(ev.args_hash) and byte_size(ev.args_hash) == 32
    end

    test "the :end event carries them too" do
      ev = events_for(read_window(1, 100)).end

      assert ev, "no tool_call :end event was broadcast"

      assert is_integer(ev.args_bytes) and ev.args_bytes > 0,
             ":end is the only phase with `success`/`duration_ms`, so an analysis " <>
               "of completed calls reads it — without the pair it falls back to the hint"

      assert is_binary(ev.args_hash) and byte_size(ev.args_hash) == 32
    end

    test "start and end agree — they describe the same call" do
      %{start: s, end: e} = events_for(read_window(1, 100))

      assert s.args_hash == e.args_hash
      assert s.args_bytes == e.args_bytes
    end
  end

  describe "the pair fixes what the hint got wrong" do
    test "two different offset windows share a hint but not a hash" do
      a = events_for(read_window(1, 100)).start
      b = events_for(read_window(101, 100)).start

      assert a.args == b.args,
             "precondition: the hint drops offset/limit, so both render as the bare path"

      refute a.args_hash == b.args_hash,
             "two different reads of one file hashed identically — this is exactly the " <>
               "collapse that turned 49 distinct offset windows into a 43.5% duplicate rate"
    end

    test "args_bytes measures the arguments, not the clipped hint" do
      command = "cd /app && python3 - << 'PY'\n" <> String.duplicate("x = 1\n", 200) <> "PY"
      ev = events_for(%{"command" => command}).start

      assert byte_size(ToolHint.summarize(%{"command" => command})) == 60,
             "precondition: the hint clips a shell command at 60 characters"

      assert ev.args_bytes > 1_000,
             "a #{byte_size(command)}-byte heredoc was logged as #{ev.args_bytes} bytes"
    end

    test "the hash is the module's, so an offline analysis can recompute it" do
      args = read_window(7, 42)
      ev = events_for(args).start

      assert ev.args_hash == ToolArgMetrics.arg_hash(args)
      assert ev.args_bytes == ToolArgMetrics.arg_bytes(args)
    end
  end

  describe "no secrets on the event log" do
    test "a credential in the arguments is never echoed into the event" do
      secret = "sk-ant-DO-NOT-LOG-ME-0123456789"
      ev = events_for(%{"command" => "deploy --token=#{secret}"}).start

      refute String.contains?(ev.args_hash, secret)

      refute String.contains?(inspect(Map.drop(ev, [:args])), secret),
             "args_bytes/args_hash must be a digest — a byte count and a truncated " <>
               "SHA-256 answer size and identity without persisting the argument text"
    end
  end
end
