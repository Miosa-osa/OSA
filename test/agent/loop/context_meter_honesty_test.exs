defmodule OptimalSystemAgent.Agent.Loop.ContextMeterHonestyTest do
  @moduledoc """
  The "N% ctx" meter must be honest from turn ZERO, not just once a provider's
  `usage` object shows up.

  Before this fix, `Loop.used_context_tokens/1` fell back to
  `Compactor.estimate_tokens(state.messages)` alone whenever
  `last_input_tokens` was still 0 — true for every session (fresh OR resumed
  from a checkpoint) until its FIRST real provider response. On an empty
  conversation that read exactly 0, even though the very next request pays a
  large FIXED cost regardless of turn count: the system-prompt static base,
  plus (for a native-tool provider) the live tool schema array. The meter
  therefore read near-0% and then LEAPT the instant the first `usage` came
  back — a real, fixed cost the pre-response estimate had simply never
  counted, not a miscount on either side of the leap.

  These tests drive a real `Agent.Loop` GenServer end to end (`SessionManager`
  + `Loop.get_state/1` + `Loop.process_message/3`) rather than re-implementing
  the fallback logic inline, so a regression in the real code path fails here
  — not just in a hand-mirrored copy of it.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Providers.Registry, as: ProviderRegistry
  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.Soul
  alias OptimalSystemAgent.Test.MockProvider
  alias OptimalSystemAgent.Tools.Audit, as: ToolAudit
  alias OptimalSystemAgent.Tools.Registry, as: ToolRegistry

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_module = Application.get_env(:optimal_system_agent, :mock_provider_module)

    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    Application.put_env(:optimal_system_agent, :mock_provider_module, MockProvider)
    MockProvider.reset()

    on_exit(fn ->
      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      if prev_module,
        do: Application.put_env(:optimal_system_agent, :mock_provider_module, prev_module),
        else: Application.delete_env(:optimal_system_agent, :mock_provider_module)
    end)

    session = "ctx-meter-" <> Integer.to_string(System.unique_integer([:positive]))

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

  test "a fresh session's ctx meter includes the static system-prompt base, not just messages",
       %{session: session} do
    assert {:ok, snap} = Loop.get_state(session)

    # Empty conversation: under the old fallback (`Compactor.estimate_tokens/1`
    # over `state.messages` alone) this was exactly 0.
    assert snap.tokens_used > 0,
           "a fresh session with no messages yet must still report the fixed " <>
             "overhead the next request is about to pay, not 0"

    # The SAME real measurement the fix uses, computed independently here so
    # the assertion is an equality against a real helper rather than a magic
    # number — robust to SYSTEM.md / the tool roster changing over time.
    lite? = Context.small_window?("mock-model-1.0", :mock)
    variant = Context.static_base_variant(:mock, lite?)
    static_floor = Soul.static_token_count(variant)

    tool_schema_floor =
      if ProviderRegistry.native_tool_schemas?(:mock) do
        ToolAudit.array_cost(ToolRegistry.list_active()).tokens
      else
        0
      end

    expected = static_floor + tool_schema_floor

    assert snap.tokens_used == expected,
           "expected the pre-response estimate to be exactly the static base " <>
             "(#{static_floor}) + native tool-schema cost (#{tool_schema_floor}) " <>
             "for an empty conversation, got #{snap.tokens_used}"

    # And it is a real floor, not a token or two: falling back to a
    # messages-only count again would read near 0 for this empty conversation.
    assert snap.tokens_used > 1_000,
           "the pre-response estimate (#{snap.tokens_used}) looks like it fell " <>
             "back to a messages-only count again"
  end

  test "the provider's real usage figure wins outright once it is reported",
       %{session: session} do
    assert {:ok, idle} = Loop.get_state(session)
    refute idle.tokens_used == 55_123

    # Drive `last_input_tokens` the same way `Accounting.maybe_put_last_input/2`
    # does after a real round-trip, on the REAL running Loop process — so this
    # exercises the actual `handle_call(:get_state, ...)` -> `used_context_tokens/1`
    # path rather than a value computed by the test itself.
    assert [{pid, _}] = Registry.lookup(OptimalSystemAgent.SessionRegistry, session)
    :sys.replace_state(pid, fn state -> %{state | last_input_tokens: 55_123} end)

    assert {:ok, snap} = Loop.get_state(session)

    assert snap.tokens_used == 55_123,
           "once a provider reports real usage, it must win outright over the " <>
             "static-base estimate — got #{snap.tokens_used}"
  end
end
