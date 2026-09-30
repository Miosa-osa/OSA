defmodule OptimalSystemAgent.Agent.Loop.CompactionNextRequestParityTest do
  @moduledoc """
  End-to-end regression for the "/compact meter jumps on the very next
  request" incident, driven through a REAL `Loop` GenServer rather than a
  bare function call.

  `MockProvider`'s usage is normally a STATIC forced number, which cannot
  prove anything about "what the next request actually sends" - a static
  number is the same whether compaction ran or not. `:mock_provider_script`
  is used instead to make each call's reported `input_tokens` an HONEST
  function of the REAL wire payload for THAT call (`Compactor.estimate_tokens/1`
  applied to the exact messages `Providers.chat/2` received, captured via
  `MockProvider.last_messages/0`). That turns the mock into a faithful stand-in
  for "what a real provider would report for this request", without depending
  on a live network call or a real tokenizer.

  The post-compaction `last_input_tokens` (what the meter shows the instant
  compaction finishes) must land close to what the VERY NEXT real request
  honestly reports - not tens of thousands of tokens / a 100%+ swing off, the
  way `estimate_tokens(compacted)` alone (dropping the system-prompt overhead)
  was.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Compactor
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev = %{
      default_provider: Application.get_env(:optimal_system_agent, :default_provider),
      mock_provider_module: Application.get_env(:optimal_system_agent, :mock_provider_module),
      mock_provider_script: Application.get_env(:optimal_system_agent, :mock_provider_script)
    }

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :mock_provider_module, MockProvider)

    # Every call honestly reports the size of what it actually received -
    # see the moduledoc. `output_tokens` is irrelevant to this test.
    Application.put_env(:optimal_system_agent, :mock_provider_script, fn messages, _opts ->
      %{
        content: "ok, continuing.",
        tool_calls: [],
        usage: %{input_tokens: Compactor.estimate_tokens(messages), output_tokens: 5}
      }
    end)

    MockProvider.reset()
    MockProvider.reset_last_messages()

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:optimal_system_agent, k)
        {k, v} -> Application.put_env(:optimal_system_agent, k, v)
      end)
    end)

    session = "compact-parity-" <> Integer.to_string(System.unique_integer([:positive]))

    :ok =
      SessionManager.ensure_loop(session,
        user_id: "test",
        working_dir: File.cwd!(),
        provider: :mock,
        model: "mock-model-1.0"
      )

    on_exit(fn -> SessionManager.cancel(session) end)
    {:ok, session: session}
  end

  defp loop_pid(session) do
    [{pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, session)
    pid
  end

  # A handful of tool-heavy turns - enough for `/compact` to have genuine
  # folding work to do, small enough to stay well clear of any automatic
  # compaction threshold on its own.
  defp heavy_turn(n) do
    id = "call_#{n}"

    [
      %{role: "user", content: "run task #{n}"},
      %{
        role: "assistant",
        content: "",
        tool_calls: [%{id: id, name: "shell_execute", arguments: %{"cmd" => "task #{n}"}}]
      },
      %{
        role: "tool",
        tool_call_id: id,
        name: "shell_execute",
        content: String.duplicate("x", 6_000)
      },
      %{role: "assistant", content: "done with task #{n}"}
    ]
  end

  test "the post-compaction total matches what the very next real request honestly sends",
       %{session: session} do
    pid = loop_pid(session)

    # Seed a tool-heavy history BEFORE the establishing call, so that call's
    # honestly-reported `input_tokens` already reflects it (system prompt +
    # this conversation), rather than growing the transcript out from under an
    # already-recorded `last_input_tokens` baseline.
    seed = Enum.flat_map(1..5, &heavy_turn/1)
    :sys.replace_state(pid, fn s -> %{s | messages: s.messages ++ seed} end)

    assert {:ok, _} = Loop.process_message(session, "please summarize", timeout: :infinity)

    state1 = :sys.get_state(pid)
    assert state1.last_input_tokens > 0, "the establishing call must have reported real usage"

    # THE BUG, reproduced as a precondition: the message-only estimate must be
    # smaller than the honestly-reported total - i.e. there IS a real
    # system-prompt/tool-schema overhead for this fix to have something to
    # preserve. If this ever fails, the test fixture stopped exercising the
    # scenario and needs revisiting, not the fix.
    message_only_before = Compactor.estimate_tokens(state1.messages)

    assert state1.last_input_tokens > message_only_before,
           "expected a real overhead gap between the honest total and the message-only estimate"

    assert {:ok, stats} = Loop.proactive_compact(session, nil)
    assert stats.messages_after < stats.messages_before, "compaction must have folded something"

    state2 = :sys.get_state(pid)

    # The GenServer's own refreshed meter must equal what `/compact` reported
    # - no silent second number living in state.
    assert state2.last_input_tokens == stats.tokens_after

    # THE FIX: the refreshed total is NOT the message-only estimate of the
    # compacted history - the overhead survived the fold.
    assert stats.tokens_after > Compactor.estimate_tokens(state2.messages),
           "tokens_after collapsed to the message-only estimate - the overhead was dropped, " <>
             "exactly the defect that made the meter read 12.6% right after a fold that the " <>
             "very next real request corrected to 31.8%"

    # Drive the VERY NEXT real request and check what it honestly sends.
    assert {:ok, _} = Loop.process_message(session, "continue", timeout: :infinity)
    real_next_total = :sys.get_state(pid).last_input_tokens

    tolerance = max(3_000, trunc(stats.tokens_after * 0.15))

    assert_in_delta real_next_total,
                    stats.tokens_after,
                    tolerance,
                    "the post-compaction estimate (#{stats.tokens_after}) is not within " <>
                      "#{tolerance} tokens of what the next real request actually sent " <>
                      "(#{real_next_total}) - the meter would visibly jump"
  end
end
