defmodule OptimalSystemAgent.Agent.Context.EvictionTest do
  @moduledoc """
  Eviction must never be silent.

  `fit_blocks/4` used to spend a fixed budget in list order and drop whatever
  did not fit — no error, no log, no signal anywhere. That is how plan mode
  disappeared from the prompt on 32k-context models after an unrelated 13KB
  prompt growth: the model simply stopped being told it was planning, and
  nothing said so.

  These tests pin the contract: a dropped essential block LOGS at warning,
  emits telemetry, and is retrievable afterwards via `Context.evictions/1`.

  `async: false` — squeezes the effective context window via application env.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalSystemAgent.Agent.Context

  setup do
    prev = Application.get_env(:optimal_system_agent, :ollama_num_ctx)
    # A window this small cannot fit the static base + reserve, so the dynamic
    # budget bottoms out at its floor and essentials are forced out.
    Application.put_env(:optimal_system_agent, :ollama_num_ctx, 8_192)

    on_exit(fn ->
      if prev do
        Application.put_env(:optimal_system_agent, :ollama_num_ctx, prev)
      else
        Application.delete_env(:optimal_system_agent, :ollama_num_ctx)
      end
    end)

    :ok
  end

  defp squeezed_state do
    %{
      session_id: "evict-#{:erlang.unique_integer([:positive])}",
      channel: :cli,
      messages: [%{role: "user", content: "refactor the retry helper"}],
      plan_mode: true,
      working_dir: "/tmp",
      provider: :ollama,
      model: "tiny-local-model"
    }
  end

  test "dropping an essential block logs loudly" do
    state = squeezed_state()

    log = capture_log(fn -> Context.build(state) end)

    assert log =~ "ESSENTIAL context block",
           "an evicted essential block must announce itself in the log"

    assert log =~ "the model will NOT see"
  end

  test "evictions are observable after the build" do
    state = squeezed_state()
    Context.build(state)

    evictions = Context.evictions(state.session_id)

    assert evictions != [], "Context.evictions/1 must surface what the budget dropped"

    for e <- evictions do
      assert e.kind in [:dropped, :truncated]
      assert is_binary(e.label)
      assert e.group in [:essential, :recall]
      assert e.wanted >= e.kept
    end

    assert Enum.any?(evictions, &(&1.group == :essential))
  end

  test "eviction emits [:osa, :context, :eviction] telemetry" do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      "evict-test-#{inspect(ref)}",
      [:osa, :context, :eviction],
      fn _event, measurements, meta, _ -> send(parent, {:evicted, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("evict-test-#{inspect(ref)}") end)

    Context.build(squeezed_state())

    assert_receive {:evicted, measurements, meta}, 1_000
    assert is_integer(measurements.wanted)
    assert meta.kind in [:dropped, :truncated]
  end

  test "evictions are per-build, not cumulative" do
    state = squeezed_state()
    Context.build(state)
    first = Context.evictions(state.session_id)

    Context.build(state)
    second = Context.evictions(state.session_id)

    assert length(second) <= length(first) + 1,
           "a rebuild must reset the eviction record, not append to it forever"
  end

  test "a session with room evicts nothing" do
    roomy = %{
      session_id: "evict-roomy-#{:erlang.unique_integer([:positive])}",
      channel: :cli,
      messages: [],
      plan_mode: false,
      working_dir: "/tmp",
      provider: :anthropic,
      model: "claude-sonnet-4-6"
    }

    Context.build(roomy)
    assert Context.evictions(roomy.session_id) == []
  end

  test "clear_evictions/1 resets the record" do
    state = squeezed_state()
    Context.build(state)
    assert Context.evictions(state.session_id) != []
    :ok = Context.clear_evictions(state.session_id)
    assert Context.evictions(state.session_id) == []
  end
end
