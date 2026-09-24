defmodule OptimalSystemAgent.Test.StepRerouteProvider do
  @moduledoc """
  Deterministic scripted provider shared by the `StepRouter` reroute tests:

    * `test/agent/loop/fast_final_answer_reroute_test.exs` — a fast-routed
      call that answers cleanly with no tool calls must be discarded and
      re-asked of the strong model.
    * `test/agent/loop/fast_model_unavailable_reroute_test.exs` — a
      fast-routed call that ERRORS must be silently re-asked of the strong
      model too, and (for a non-retryable reason) mark the pairing
      unavailable.

  Call 1 is always a mechanical tool call (`file_read`) — evidence
  `StepRouter` reads to route the NEXT call to the fast model. Every call
  after that is either a scripted failure (`fail_calls/2`, while armed) or a
  scripted answer: `fast_answer/0` for the FIRST successful post-tool-call
  answer when no failure was ever armed this run (the clean-discard test),
  or `strong_answer/0` for every successful post-tool-call answer once a
  failure WAS armed (the unavailable-reroute test never has a legitimate
  "fast answer" to guard against — only "did the error get replaced by a
  working answer").

  ETS-backed, not the process dictionary: `LLMClient.llm_chat_stream/3` runs
  the actual provider call inside a freshly `Task.async`'d process on EVERY
  call, so a `Process.get/put` counter would never see call 2 (a new, empty
  dictionary every time) — the same hazard `MockProvider.queue_final_texts/1`
  documents and works around the same way. A single fail flag consumed on
  the very next call is NOT enough either: Registry's own same-provider
  resilience (`stream_with_fallback/5`'s native attempt + same-provider sync
  fallback) can call `chat/2` MORE THAN ONCE for what is, from ReactLoop's
  point of view, a single fast-routed step — `fail_calls/2` therefore takes
  an explicit count of attempts to fail, sized to cover however many of
  those internal retries actually happen.
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  @table :osa_step_reroute_provider

  @doc "The fast model's answer — must never reach the user (clean-discard test)."
  def fast_answer, do: "FAST_MODEL_ANSWER: task looks done."

  @doc "The strong model's answer — the correct final answer in both tests."
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

      n ->
        case maybe_fail() do
          {:error, reason} ->
            {:error, reason}

          :ok ->
            if failure_ever_armed?() or n != 2 do
              {:ok, %{content: strong_answer(), tool_calls: []}}
            else
              {:ok, %{content: fast_answer(), tool_calls: []}}
            end
        end
    end
  end

  @doc """
  Arm the next `count` calls to fail with `reason` instead of answering —
  for the fast-model-unavailable reroute test. `count` should cover however
  many internal attempts Registry's own resilience layer makes for ONE
  fast-routed step (native stream + same-provider sync fallback, observed as
  2); pad generously rather than exactly, since a call past the armed count
  simply answers normally.
  """
  def fail_calls(reason, count) when is_integer(count) and count > 0 do
    :ets.insert(table(), {:fail_reason, reason})
    :ets.insert(table(), {:fail_remaining, count})
    :ets.insert(table(), {:failure_armed, true})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp maybe_fail do
    case :ets.lookup(table(), :fail_remaining) do
      [{:fail_remaining, n}] when n > 0 ->
        :ets.insert(table(), {:fail_remaining, n - 1})
        [{:fail_reason, reason}] = :ets.lookup(table(), :fail_reason)
        {:error, reason}

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp failure_ever_armed? do
    case :ets.lookup(table(), :failure_armed) do
      [{:failure_armed, true}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Reset all scripted state (call in test setup)."
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
