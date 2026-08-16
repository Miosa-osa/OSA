defmodule OptimalSystemAgent.Test.MockProvider do
  @moduledoc """
  Deterministic LLM provider for E2E tests.

  Returns a canned tool_call on the first invocation per process, then a
  plain-text response on every subsequent call.  State is kept in the
  calling process's dictionary so it is automatically isolated per test
  (each test spawns its own Loop GenServer which has its own dictionary).

  To use:
    1. In setup, call `MockProvider.reset/0` to clear any prior state.
    2. Configure the application to use the :mock provider atom:
         Application.put_env(:optimal_system_agent, :default_provider, :mock)
    3. Register the module under the :mock atom so the registry resolves it:
         Application.put_env(:optimal_system_agent, :mock_provider_module, __MODULE__)
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  # ── Behaviour callbacks ──────────────────────────────────────────────

  @impl true
  def name, do: :mock

  @impl true
  def default_model, do: "mock-model-1.0"

  @impl true
  def available_models, do: ["mock-model-1.0"]

  @doc """
  Synchronous chat.

  First call (per process): returns a tool_call response.
  Subsequent calls: returns a plain-text final answer.

  When `Application.get_env(:optimal_system_agent, :mock_provider_sleep_ms)`
  is set, sleeps that long BEFORE responding — used to deterministically
  simulate a subagent stuck inside one long provider call (delegation
  timeout/cancel robustness tests) without a real network dependency.
  """
  @impl true
  def chat(_messages, opts) do
    maybe_sleep()
    bump_round_trips()
    record_opts(opts)

    result =
      case forced_final_text() do
        nil -> chat_scripted()
        text -> {:ok, %{content: text, tool_calls: []}}
      end

    case with_forced_usage(result) do
      {:ok, resp} -> {:ok, with_forced_stop_reason(resp)}
      other -> other
    end
  end

  # Real providers return a `:usage` map; this mock did not, which made it
  # useless for testing anything about cost accounting. Opt-in via
  # `:mock_provider_usage` so every existing test's response shape is byte-for-
  # byte unchanged when the key is unset.
  defp with_forced_usage({:ok, resp}) do
    case Application.get_env(:optimal_system_agent, :mock_provider_usage) do
      usage when is_map(usage) -> {:ok, Map.put(resp, :usage, usage)}
      _ -> {:ok, resp}
    end
  end

  defp with_forced_usage(other), do: other

  # Real providers report a terminal stop/finish reason; this mock did not, so
  # nothing could test the harness's truncation handling end to end — the exact
  # gap that let a generation cut off at the output ceiling be delivered as a
  # final answer. Opt-in via `:mock_provider_stop_reason` (a RAW provider
  # spelling: "length", "max_tokens", "MAX_TOKENS", "max_output_tokens", …) so
  # every existing test's response shape is byte-for-byte unchanged when unset.
  @spec with_forced_stop_reason(map()) :: map()
  def with_forced_stop_reason(resp) when is_map(resp) do
    case Application.get_env(:optimal_system_agent, :mock_provider_stop_reason) do
      r when is_binary(r) and r != "" -> Map.put(resp, :stop_reason, r)
      _ -> resp
    end
  end

  defp chat_scripted do
    case Process.get(:mock_provider_call_count, 0) do
      0 ->
        Process.put(:mock_provider_call_count, 1)

        {:ok,
         %{
           content: "",
           tool_calls: [
             %{
               id: "call_mock_001",
               name: "memory_recall",
               arguments: %{"query" => "smoke test context"}
             }
           ]
         }}

      _ ->
        Process.put(:mock_provider_call_count, :done)
        {:ok, %{content: "Mock final answer from OSA.", tool_calls: []}}
    end
  end

  @doc """
  Streaming chat — simulates the three-phase callback sequence and then
  invokes `{:done, result}` so the Loop's process-dictionary capture works.
  """
  @impl true
  def chat_stream(_messages, callback, _opts) do
    maybe_sleep()
    bump_round_trips()

    case forced_final_text() do
      nil ->
        chat_stream_scripted(callback)

      text ->
        # `""` means "finish the turn with NO final text" — the silent-child
        # case the delegation result-recovery path exists for.
        if text != "", do: callback.({:text_delta, text})
        callback.({:done, with_forced_stop_reason(%{content: text, tool_calls: []})})
        :ok
    end
  end

  defp chat_stream_scripted(callback) do
    case Process.get(:mock_provider_call_count, 0) do
      0 ->
        Process.put(:mock_provider_call_count, 1)

        result = %{
          content: "",
          tool_calls: [
            %{
              id: "call_mock_001",
              name: "memory_recall",
              arguments: %{"query" => "smoke test context"}
            }
          ]
        }

        callback.({:done, result})
        :ok

      _ ->
        Process.put(:mock_provider_call_count, :done)
        text = "Mock final answer from OSA."
        callback.({:text_delta, text})
        result = %{content: text, tool_calls: []}
        callback.({:done, result})
        :ok
    end
  end

  @doc "Reset the per-process call counter (call in test setup)."
  def reset do
    Process.delete(:mock_provider_call_count)
    :ok
  end

  # ── Cross-process round-trip counter ─────────────────────────────────────
  #
  # `chat/2` and `chat_stream/3` are invoked from short-lived task processes
  # that do NOT inherit the test process's dictionary, so the per-process
  # counter above cannot answer "how many model round-trips did that turn
  # cost?". This counter lives in a public named ETS table owned by whichever
  # process first touches it, which makes it readable from the test process
  # after the loop has finished.

  @counter_table :osa_mock_provider_round_trips

  defp counter_table do
    case :ets.whereis(@counter_table) do
      :undefined ->
        try do
          :ets.new(@counter_table, [:named_table, :public, :set])
        rescue
          # Lost the race with a concurrent creator — the table now exists.
          ArgumentError -> @counter_table
        end

      _ref ->
        @counter_table
    end
  end

  defp bump_round_trips do
    :ets.update_counter(counter_table(), :round_trips, {2, 1}, {:round_trips, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # The opts of the most recent `chat/2`, in the same public table.
  #
  # Exists so a test can assert what actually reached the wire rather than what
  # a caller intended — the null-model 422 was invisible precisely because the
  # compactor's own `summarizer_model/1` resolved a correct name that was only
  # ever used for BILLING, never put on the request.
  defp record_opts(opts) when is_list(opts) do
    :ets.insert(counter_table(), {:last_opts, opts})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp record_opts(_), do: :ok

  @doc "Opts of the most recent `chat/2` call, or `nil` if there has been none."
  @spec last_opts() :: keyword() | nil
  def last_opts do
    case :ets.lookup(counter_table(), :last_opts) do
      [{:last_opts, opts}] -> opts
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Forget the recorded opts (call in test setup)."
  @spec reset_last_opts() :: :ok
  def reset_last_opts do
    :ets.delete(counter_table(), :last_opts)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Number of provider round-trips since the last `reset_round_trips/0`."
  @spec round_trips() :: non_neg_integer()
  def round_trips do
    case :ets.lookup(counter_table(), :round_trips) do
      [{:round_trips, n}] -> n
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Zero the cross-process round-trip counter (call in test setup)."
  @spec reset_round_trips() :: :ok
  def reset_round_trips do
    :ets.insert(counter_table(), {:round_trips, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # When `:mock_provider_final_text` is set, EVERY call answers with that text
  # and no tool calls, so a subagent finishes its turn in one deterministic hop.
  # Set it to `""` to simulate a child that ends its turn producing no text at
  # all. Unset (the default) keeps the original tool-call-then-answer script,
  # so existing tests are untouched. Read from application env rather than the
  # process dictionary because the Loop invokes the provider from short-lived
  # task processes that do not inherit the test process's dictionary.
  defp forced_final_text do
    case Application.get_env(:optimal_system_agent, :mock_provider_final_text) do
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  defp maybe_sleep do
    case Application.get_env(:optimal_system_agent, :mock_provider_sleep_ms) do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end
end
