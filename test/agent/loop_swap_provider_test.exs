defmodule OptimalSystemAgent.Agent.LoopSwapProviderTest do
  @moduledoc """
  Regression coverage for `Loop.handle_call({:swap_provider, ...})` — the
  session-scoped hot-swap the TUI's `/model` command (and the model picker's
  "save key and switch") must land on so the CURRENT live session actually
  uses the new provider/model on its next turn.

  Called directly against `handle_call/3` (no GenServer needed — it is a pure
  function of `{msg, from, state}`), mirroring `loop_unit_test.exs`'s pattern
  of testing Loop internals without starting a live process.

  Context: the TUI previously called `POST /api/v1/models/switch` (global
  Application-env defaults only) for `/model`, which never reached this
  `handle_call` clause at all — the header/toast reported success but the
  running session's `state.provider`/`state.model` never changed, so the next
  turn silently kept calling the OLD provider. The fix routes the TUI through
  `POST /api/v1/sessions/:id/provider` (`SessionManager.swap_provider/3`),
  which calls this clause on the live `Loop` GenServer.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Loop

  defp base_state(overrides \\ %{}) do
    struct(
      %Loop{session_id: "swap-provider-test", provider: :anthropic, model: "claude-x"},
      overrides
    )
  end

  test "swaps provider and model on the live state" do
    state = base_state()

    assert {:reply, {:ok, %{provider: :ollama, model: "qwen3:8b"}}, new_state} =
             Loop.handle_call({:swap_provider, "ollama", "qwen3:8b"}, self(), state)

    assert new_state.provider == :ollama
    assert new_state.model == "qwen3:8b"
    # The whole point: the NEXT turn reads state.provider/state.model (via
    # LLMClient.llm_chat_stream/3, which takes the Loop state map as-is), so
    # this must have actually changed rather than merely echoing the request.
    refute new_state.provider == state.provider
  end

  test "accepts a string provider (as sent by the HTTP route's JSON body)" do
    state = base_state()

    assert {:reply, {:ok, %{provider: provider_atom}}, new_state} =
             Loop.handle_call({:swap_provider, "ollama", "llama3"}, self(), state)

    assert provider_atom == :ollama
    assert new_state.provider == :ollama
  end

  test "rejects an unknown provider without mutating state" do
    state = base_state()

    assert {:reply, {:error, msg}, unchanged} =
             Loop.handle_call(
               {:swap_provider, "not_a_real_provider", "some-model"},
               self(),
               state
             )

    assert msg =~ "unknown provider"
    assert unchanged == state
  end

  test "rejects a missing/blank model without mutating state" do
    state = base_state()

    assert {:reply, {:error, msg}, unchanged} =
             Loop.handle_call({:swap_provider, "ollama", ""}, self(), state)

    assert msg =~ "model is required"
    assert unchanged == state

    assert {:reply, {:error, _msg}, ^unchanged} =
             Loop.handle_call({:swap_provider, "ollama", nil}, self(), state)
  end
end
