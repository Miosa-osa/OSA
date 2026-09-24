defmodule OptimalSystemAgent.Test.StepRerouteProvider do
  @moduledoc """
  Deterministic 3-call script for the fast-final-answer reroute test
  (`test/agent/loop/fast_final_answer_reroute_test.exs`):

    1. a mechanical tool call (`file_read`) — evidence `StepRouter` reads to
       route the NEXT call to the fast model.
    2. plain text, NO tool calls — the fast model answering when it should
       have asked for another tool. This must be discarded, never delivered.
    3. plain text, NO tool calls — the strong model's re-ask. This is what
       must reach the user.

  ETS-backed counter, not the process dictionary: `LLMClient.llm_chat_stream/3`
  runs the actual provider call inside a freshly `Task.async`'d process on
  EVERY call, so a `Process.get/put` counter would never see call 2 (a new,
  empty dictionary every time) — the same hazard `MockProvider.queue_final_
  texts/1`'s own moduledoc documents and works around the same way.
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  @table :osa_step_reroute_provider

  @doc "The fast model's answer — must never reach the user."
  def fast_answer, do: "FAST_MODEL_ANSWER: task looks done."

  @doc "The strong model's answer — the correct final answer."
  def strong_answer, do: "STRONG_MODEL_ANSWER: task is done."

  @impl true
  def name, do: :step_reroute_mock

  @impl true
  def default_model, do: "step-reroute-strong"

  @impl true
  def chat(_messages, _opts) do
    case bump() do
      1 ->
        {:ok,
         %{
           content: "",
           tool_calls: [%{id: "call_reroute_1", name: "file_read", arguments: %{"path" => "."}}]
         }}

      2 ->
        {:ok, %{content: fast_answer(), tool_calls: []}}

      _ ->
        {:ok, %{content: strong_answer(), tool_calls: []}}
    end
  end

  @doc "Reset the call counter (call in test setup)."
  def reset do
    :ets.delete_all_objects(table())
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Number of `chat/2` calls since the last `reset/0`."
  def calls do
    case :ets.lookup(table(), :n) do
      [{:n, n}] -> n
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp bump, do: :ets.update_counter(table(), :n, {2, 1}, {:n, 0})

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> @table
        end

      _ref ->
        @table
    end
  end
end
