defmodule OptimalSystemAgent.Agent.Loop.LLMClientCacheStatusTest do
  @moduledoc """
  The `:llm_response` PubSub broadcast is the one place the TUI's prompt-cache
  status-line chip gets its numbers from. This pins the wire shape: the raw
  cache token counts ride alongside the existing input/output counts, and a
  compact `cache_status` is read back from `CacheAttribution` for this
  session — whatever the (real) provider already recorded there while the
  request was in flight, via the SAME `session_id`-keyed scope every provider
  uses (`CacheAttribution.scope/1`).

  `MockProvider` stands in for the provider's HTTP round-trip, but not for
  `CacheAttribution.observe/3` — that call lives inside the real provider
  modules (`Anthropic`/`Bedrock`/`OpenAICompat`), not in the mock. So these
  tests record the attribution state directly, exactly as a real provider
  would have by the time this callback runs, and separately control what
  `usage` map the mock hands back for the raw token-count fields.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.LLMClient
  alias OptimalSystemAgent.Providers.CacheAttribution
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_provider = Application.get_env(:optimal_system_agent, :default_provider)
    Application.put_env(:optimal_system_agent, :default_provider, :mock)
    MockProvider.reset()
    MockProvider.reset_round_trips()

    on_exit(fn ->
      if prev_provider,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev_provider),
        else: Application.delete_env(:optimal_system_agent, :default_provider)

      Application.delete_env(:optimal_system_agent, :mock_provider_usage)
    end)

    :ok
  end

  defp state(session_id) do
    %{provider: :mock, model: "mock-model-1.0", session_id: session_id}
  end

  test "the broadcast carries raw cache token counts and a compact cache_status" do
    session_id = "cache-status-#{System.unique_integer([:positive])}"
    CacheAttribution.reset(session_id)

    # What a real provider would already have recorded for this session by
    # the time llm_client's :done callback runs.
    fp = CacheAttribution.fingerprint(%{model: "mock-model-1.0"})
    usage = %{cache_read_input_tokens: 9_000, input_tokens: 10_000}
    CacheAttribution.observe(session_id, fp, usage)

    # What the mock hands back on the wire — independent of the above, since
    # the mock never calls CacheAttribution itself.
    Application.put_env(:optimal_system_agent, :mock_provider_usage, %{
      input_tokens: 10_000,
      output_tokens: 200,
      cache_read_input_tokens: 9_000,
      cache_creation_input_tokens: 0
    })

    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    assert {:ok, _result} =
             LLMClient.llm_chat_stream(state(session_id), [%{role: "user", content: "hi"}], [])

    assert_receive {:osa_event, %{type: :llm_response} = event}, 2_000

    assert event.usage.input_tokens == 10_000
    assert event.usage.cache_read_input_tokens == 9_000
    assert event.usage.cache_creation_input_tokens == 0

    assert_in_delta event.cache_status.hit_rate, 0.9, 0.0001
    assert event.cache_status.last_break == nil
    assert event.cache_status.token_cost == 0
  end

  test "cache_status.hit_rate is nil when nothing has been observed for this session yet" do
    session_id = "cache-status-cold-#{System.unique_integer([:positive])}"
    CacheAttribution.reset(session_id)

    Application.put_env(:optimal_system_agent, :mock_provider_usage, %{
      input_tokens: 0,
      output_tokens: 5
    })

    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    assert {:ok, _result} =
             LLMClient.llm_chat_stream(state(session_id), [%{role: "user", content: "hi"}], [])

    assert_receive {:osa_event, %{type: :llm_response} = event}, 2_000
    assert event.cache_status.hit_rate == nil
  end

  test "a subsequent break shows up in cache_status.last_break and token_cost" do
    session_id = "cache-status-break-#{System.unique_integer([:positive])}"
    CacheAttribution.reset(session_id)

    warm_fp = CacheAttribution.fingerprint(%{model: "mock-model-1.0", max_tokens: 8_192})
    cold_fp = CacheAttribution.fingerprint(%{model: "mock-model-1.0", max_tokens: 4_096})

    CacheAttribution.observe(session_id, warm_fp, %{
      cache_read_input_tokens: 9_000,
      input_tokens: 10_000
    })

    {:break, verdict} =
      CacheAttribution.observe(session_id, cold_fp, %{
        cache_read_input_tokens: 0,
        input_tokens: 10_000
      })

    Application.put_env(:optimal_system_agent, :mock_provider_usage, %{
      input_tokens: 10_000,
      output_tokens: 50,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 10_000
    })

    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    assert {:ok, _result} =
             LLMClient.llm_chat_stream(state(session_id), [%{role: "user", content: "hi"}], [])

    assert_receive {:osa_event, %{type: :llm_response} = event}, 2_000
    assert event.cache_status.last_break == verdict
    assert event.cache_status.token_cost == 9_000
  end
end
