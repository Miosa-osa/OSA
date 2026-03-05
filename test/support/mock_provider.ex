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
  """
  @impl true
  def chat(_messages, _opts) do
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
    case Process.get(:mock_provider_call_count, 0) do
      0 ->
        Process.put(:mock_provider_call_count, 1)
        result = %{content: "", tool_calls: [%{id: "call_mock_001", name: "memory_recall", arguments: %{"query" => "smoke test context"}}]}
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
end
