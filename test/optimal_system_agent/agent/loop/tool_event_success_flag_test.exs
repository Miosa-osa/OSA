defmodule OptimalSystemAgent.Agent.Loop.ToolEventSuccessFlagTest do
  @moduledoc """
  The `success` flag on the tool_call `:end` event that reaches the TUI.

  The TUI's SSE stream is fed by the session-scoped PubSub topic
  `osa:session:<id>` (see `SessionRoutes` `GET /:id/stream`), and the `:end`
  frame broadcast there carried a HARD-CODED `success: true`. Every failed tool
  call therefore arrived at the screen labelled as a success — so the transcript's
  error glyph and error body could never fire, and the operator had no way to
  tell a tool that blew up from one that worked.

  The sibling `Bus.emit` on the same code path already computed the real value;
  only the broadcast the TUI actually reads threw it away.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Tools.Registry

  @registry_key {Registry, :builtin_tools}

  defmodule OkTool do
    @moduledoc false
    def name, do: "test_flag_ok_tool"
    def description, do: "succeeds"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args), do: {:ok, "all good"}
  end

  defmodule FailTool do
    @moduledoc false
    def name, do: "test_flag_fail_tool"
    def description, do: "fails"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def execute(_args), do: {:error, "the file was not found in the workspace"}
  end

  @stubs %{
    "test_flag_ok_tool" => OkTool,
    "test_flag_fail_tool" => FailTool
  }

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

  defp call(name),
    do: %{id: "tc-#{System.unique_integer([:positive, :monotonic])}", name: name, arguments: %{}}

  # Run `tool` and return the tool_call `:end` event as the TUI receives it.
  #
  # The session id must be unique across BEAM RUNS, not just within one:
  # `durable_log_dir` is a shared `/tmp` directory in the test env, and
  # `System.unique_integer/1` restarts low on every `mix test`. A counter-only id
  # therefore collided with a previous run's recorded step, and `DurableLog`
  # replayed it — returning the recorded result without re-executing and WITHOUT
  # emitting any tool_call event. That made this test pass or fail depending on
  # what earlier runs had left on disk.
  defp end_event(tool) do
    session_id =
      "tool-flag-#{System.unique_integer([:positive, :monotonic])}-" <>
        (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

    on_exit_clear(session_id)
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    ToolExecutor.execute_tool_call(call(tool), state(session_id))

    collect_end()
  end

  defp on_exit_clear(session_id) do
    ExUnit.Callbacks.on_exit(fn ->
      OptimalSystemAgent.Agent.Loop.DurableLog.clear(session_id)
    end)
  end

  # Drain non-matching frames (the `start` event, task/telemetry chatter) until
  # the `end` frame arrives. Returns nil on timeout so the assertion can say
  # "no event was broadcast" rather than blowing up on a shape mismatch.
  defp collect_end do
    receive do
      {:osa_event, %{type: :tool_call, phase: "end"} = ev} -> ev
      _other -> collect_end()
    after
      2_000 -> nil
    end
  end

  test "a failed tool reaches the TUI labelled as a failure" do
    ev = end_event("test_flag_fail_tool")

    assert ev, "no tool_call :end event was broadcast on the session topic"
    assert ev.success == false, "a failed tool was broadcast as success=#{inspect(ev.success)}"
  end

  test "a successful tool still reaches the TUI labelled as a success" do
    ev = end_event("test_flag_ok_tool")

    assert ev, "no tool_call :end event was broadcast on the session topic"
    assert ev.success == true
  end

  test "the :end event carries a duration the TUI can render" do
    ev = end_event("test_flag_ok_tool")

    assert ev
    assert is_integer(ev.duration_ms), "duration_ms must be present and numeric"
    assert ev.duration_ms >= 0, "a monotonic-clock duration is never negative"
  end
end
