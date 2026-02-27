defmodule OptimalSystemAgent.SDK.Signal do
  @moduledoc """
  SDK wrapper for Signal Theory classification.

  Exposes the 5-tuple S=(M,G,T,F,W) signal classification for SDK consumers.
  Every message has a Signal — mode, genre, type, format, weight.
  """

  alias OptimalSystemAgent.Signal.Classifier

  @doc """
  Classify a message into its Signal Theory 5-tuple.

  Returns `%Classifier{}` with:
  - `:mode` — `:execute | :assist | :analyze | :build | :maintain`
  - `:genre` — `:direct | :inform | :commit | :decide | :express`
  - `:type` — String (e.g., "request", "question", "report")
  - `:format` — `:message | :document | :notification | :command | :transcript`
  - `:weight` — float 0.0-1.0 (Shannon information content)
  - `:confidence` — `:high | :low`

  ## Example

      signal = OSA.SDK.Signal.classify("Fix the authentication bug")
      # => %Classifier{mode: :execute, genre: :direct, type: "request",
      #      format: :message, weight: 0.85, confidence: :high}
  """
  @spec classify(String.t(), atom()) :: Classifier.t()
  def classify(message, channel \\ :sdk) do
    Classifier.classify(message, channel)
  end

  @doc """
  Calculate the Shannon weight of a message (0.0-1.0).

  Higher weight = more actionable/information-dense.
  """
  @spec weight(String.t()) :: float()
  def weight(message) do
    Classifier.calculate_weight(message)
  end
end
