defmodule OptimalSystemAgent.Verification.Confidence do
  @moduledoc """
  Confidence tracking for verification loops.

  Maintains a rolling window of pass/fail results per loop and computes
  a confidence score used to decide whether to escalate to human review.

  - Score: `pass_count / window_size * 100` (0–100)
  - Escalation threshold: configurable, default 20%
  - Trend: computed from the slope across the rolling window
  """

  @default_window 5
  @default_escalate_threshold 20.0

  defstruct results: [],
            window: @default_window,
            escalate_threshold: @default_escalate_threshold

  @type result :: :pass | :fail
  @type trend :: :improving | :stable | :declining

  @type t :: %__MODULE__{
          results: [result()],
          window: pos_integer(),
          escalate_threshold: float()
        }

  @doc "Create a new confidence tracker."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      window: Keyword.get(opts, :window, @default_window),
      escalate_threshold: Keyword.get(opts, :escalate_threshold, @default_escalate_threshold)
    }
  end

  @doc """
  Record a new result and return the updated tracker.

  Keeps only the most recent `window` results.
  """
  @spec update(t(), result()) :: t()
  def update(%__MODULE__{} = tracker, result) when result in [:pass, :fail] do
    results = [result | tracker.results] |> Enum.take(tracker.window)
    %{tracker | results: results}
  end

  @doc """
  Compute the current confidence score (0.0–100.0).

  Returns 0.0 when no results have been recorded yet.
  """
  @spec score(t()) :: float()
  def score(%__MODULE__{results: []}), do: 0.0

  def score(%__MODULE__{results: results}) do
    pass_count = Enum.count(results, &(&1 == :pass))
    pass_count / length(results) * 100.0
  end

  @doc """
  Return `true` when the current confidence score is below the escalation
  threshold. An empty result set is treated as below threshold.
  """
  @spec should_escalate?(t()) :: boolean()
  def should_escalate?(%__MODULE__{results: []}), do: true

  def should_escalate?(%__MODULE__{} = tracker) do
    score(tracker) < tracker.escalate_threshold
  end

  @doc """
  Compute the confidence trend over the rolling window.

  Uses the difference between the first and second halves of the result
  window to determine direction. Requires at least 2 results.

  Returns `:stable` when there is insufficient history.
  """
  @spec trend(t()) :: trend()
  def trend(%__MODULE__{results: results}) when length(results) < 2, do: :stable

  def trend(%__MODULE__{results: results}) do
    # Results are stored newest-first; reverse for chronological order.
    chronological = Enum.reverse(results)
    mid = div(length(chronological), 2)

    {first_half, second_half} = Enum.split(chronological, mid)

    first_score = half_score(first_half)
    second_score = half_score(second_half)

    cond do
      second_score > first_score + 10.0 -> :improving
      first_score > second_score + 10.0 -> :declining
      true -> :stable
    end
  end

  @doc "Summarize tracker state as a plain map for logging or serialization."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = tracker) do
    %{
      score: score(tracker),
      trend: trend(tracker),
      should_escalate: should_escalate?(tracker),
      result_count: length(tracker.results),
      window: tracker.window,
      escalate_threshold: tracker.escalate_threshold
    }
  end

  # --- Private ---

  defp half_score([]), do: 0.0

  defp half_score(results) do
    pass_count = Enum.count(results, &(&1 == :pass))
    pass_count / length(results) * 100.0
  end
end
