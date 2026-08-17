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
      assert e.group in [:essential, :optional, :recall]
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
    # Isolate from the host's installed skills catalog: the recall block is
    # hard-capped, so a large real catalog truncates (an eviction) regardless of
    # window room, making this host-dependent. Empty the registry for a
    # deterministic check; on_exit restores it.
    skills_key = {OptimalSystemAgent.Tools.Registry, :skills}
    prev_skills = :persistent_term.get(skills_key, %{})
    :persistent_term.put(skills_key, %{})
    on_exit(fn -> :persistent_term.put(skills_key, prev_skills) end)

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

  describe "severity means something" do
    # Every world-state eviction used to be recorded as `group: :essential`,
    # because `fit_world_state/3` passed that atom as a constant. The tool-usage
    # doctrine (rank 0) and the slash-command catalog (rank 3) were announced at
    # identical severity, which is what made a real capability loss look like
    # routine noise on Terminal-Bench.
    test "a rank-0 section is essential and a catalog is not" do
      state = squeezed_state()
      Context.build(state)

      by_label =
        state.session_id
        |> Context.evictions()
        |> Map.new(&{&1.label, &1.group})

      assert by_label["ws:tools"] == :essential,
             "the tool-usage doctrine is rank 0 — losing it is a capability regression"

      for catalog <- ["ws:apps", "ws:agent_roles"] do
        case Map.fetch(by_label, catalog) do
          {:ok, group} ->
            assert group == :optional,
                   "#{catalog} is a rank-3 catalog; calling it ESSENTIAL empties the word"

          :error ->
            :ok
        end
      end
    end

    test "an optional drop is still logged, just not as ESSENTIAL" do
      # The test env pins the primary Logger at :warning, so an :info line never
      # reaches the capture handler. Lower it for this assertion only — the point
      # is that the line EXISTS at a visible level, not that a warning-filtered
      # runtime happens to show it.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log = capture_log([level: :info], fn -> Context.build(squeezed_state()) end)

      assert log =~ "optional context block",
             "under-reporting a low-rank drop would recreate the silent-drop bug"

      refute log =~ "ESSENTIAL context block dropped: label=ws:apps"
    end
  end

  describe "an unfittable prompt fails loudly" do
    # The dynamic budget's 1_000-token floor is a fiction when the static base
    # plus the conversation already exceed the window: the honest number is
    # negative. Absorbing that silently is what let five eviction warnings stand
    # in for the real fault, sending the investigation to the wrong module.
    test "the shortfall is reported at :error, with the arithmetic" do
      log = capture_log(fn -> Context.build(squeezed_state()) end)

      assert log =~ "PROMPT DOES NOT FIT"
      assert log =~ "window=8192"
      assert log =~ "SYMPTOM"
    end

    test "it emits [:osa, :context, :overflow] telemetry" do
      handler = "overflow-test-#{:erlang.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:osa, :context, :overflow],
        fn _e, m, meta, _ -> send(parent, {:overflow, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Context.build(squeezed_state())

      assert_receive {:overflow, measurements, meta}, 1_000
      assert measurements.raw_budget < 0
      assert meta.fits == false
    end

    test "a prompt that fits reports nothing" do
      handler = "overflow-quiet-#{:erlang.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:osa, :context, :overflow],
        fn _e, m, meta, _ -> send(parent, {:overflow, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Context.build(%{
        session_id: "overflow-quiet-#{:erlang.unique_integer([:positive])}",
        channel: :cli,
        messages: [],
        working_dir: "/tmp",
        provider: :anthropic,
        model: "claude-sonnet-4-6"
      })

      refute_receive {:overflow, _, _}, 200
    end
  end

  describe "window resolution when the state carries no model" do
    # `model: nil` is what every non-CLI entry point produces, `serve`/HTTP
    # included. Resolved raw it cannot match the ":cloud" tag test that exempts
    # hosted tags from the local KV-cache ceiling, so a 1M-window cloud model was
    # budgeted as a 32k local one — MEASURED on Terminal-Bench as a 30x
    # under-budget that gutted the world state for a window that was never real.
    #
    # ## What this test may NOT assert
    #
    # It used to end on `assert Context.evictions(session) == []`, which reads
    # like a statement about the window and is in fact a statement about the
    # GLOBAL long-term memory store. `Memory.Store` is a singleton GenServer
    # over named ETS tables and one SQLite file; the suite shares it by design,
    # and long-term memory is cross-session by definition, so there is nothing
    # per-test about it to isolate. MEASURED: with an empty store this build
    # evicts nothing, and after ONE `Memory.save/2` of the 6,900-char row that
    # `Memory.StoreMergeTest` ("an oversized existing entry is not appended to")
    # leaves behind, the same build records
    #
    #     %{label: "memory", group: :recall, kind: :truncated, wanted: 1204, kept: 1196}
    #
    # — the recall block truncated to `Budget.memory_context_token_cap/0`. That
    # row has ZERO lexical overlap with "refactor the retry helper". It reaches
    # the prompt because `Memory.recall_hybrid/2` unions in `recent(100)`
    # unconditionally, and it clears the 0.35 floor on category weight
    # (0.50 * 0.30) plus recency (~1.0 * 0.20) alone — landing within 1e-5 of
    # the cutoff, which is why it flips with a few seconds of elapsed time and
    # why the same seed passed on one machine and failed on another.
    #
    # So the empty-list assertion was a clock and a store census wearing the
    # costume of a window check. What replaces it below is strictly about the
    # window, and still fails if the window resolves wrong:
    #
    #   * under the 8,192 local ceiling the prompt provably does not fit at all
    #     (static base 11,575 > window), so `[:osa, :context, :overflow]` fires
    #     on every build; under the resolved 1M window it never fires. That
    #     event IS the window resolution, observed.
    #   * a wrong window also drops `ws:tools`, an ESSENTIAL block — so both the
    #     log refutation and the group assertion below still catch it.
    #
    # Recall truncation is excluded, and only recall truncation: it is the one
    # outcome the shared store can produce on its own.
    test "a nil model budgets against the configured model, not the local ceiling" do
      prev = Application.get_env(:optimal_system_agent, :ollama_model)
      Application.put_env(:optimal_system_agent, :ollama_model, "glm-5.2:cloud")

      handler = "nil-model-window-#{:erlang.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:osa, :context, :overflow],
        fn _e, m, meta, _ -> send(parent, {:overflow, m, meta}) end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler)

        if prev,
          do: Application.put_env(:optimal_system_agent, :ollama_model, prev),
          else: Application.delete_env(:optimal_system_agent, :ollama_model)
      end)

      state = %{squeezed_state() | model: nil}

      log = capture_log(fn -> Context.build(state) end)

      refute log =~ "ESSENTIAL context block",
             "an Ollama Cloud tag keeps its full window; no essential block should be evicted"

      refute_receive {:overflow, _, _},
                     200,
                     "the prompt overflowed, so `model: nil` was budgeted against the local " <>
                       "num_ctx ceiling instead of the configured glm-5.2:cloud window"

      for e <- Context.evictions(state.session_id) do
        assert e.group == :recall,
               "a full cloud window must not evict #{e.group} block #{e.label}; only the " <>
                 "recall group may be trimmed, and only by what the shared memory store holds"
      end
    end
  end

  test "clear_evictions/1 resets the record" do
    state = squeezed_state()
    Context.build(state)
    assert Context.evictions(state.session_id) != []
    :ok = Context.clear_evictions(state.session_id)
    assert Context.evictions(state.session_id) == []
  end
end
