defmodule OptimalSystemAgent.Events.Classifier do
  @moduledoc """
  Signal Theory 5-tuple classifier for internal Event structs.

  Infers the five Signal dimensions (mode, genre, type, format, structure)
  from an `OptimalSystemAgent.Events.Event` struct using deterministic
  pattern matching.  No LLM, no I/O — always < 1ms.

  Reference: Luna, R. (2026). Signal Theory: The Architecture of Optimal
  Intent Encoding in Communication Systems.
  """

  alias OptimalSystemAgent.Events.Event

  @doc """
  Classify an Event into the 5-tuple Signal dimensions.

  Returns a plain map with keys: :mode, :genre, :type, :format, :structure
  """
  @spec classify(Event.t()) :: %{
          mode: atom(),
          genre: atom(),
          type: atom(),
          format: atom(),
          structure: atom()
        }
  def classify(%Event{} = event) do
    %{
      mode: infer_mode(event),
      genre: infer_genre(event),
      type: infer_type(event),
      format: infer_format(event),
      structure: infer_structure(event)
    }
  end

  @doc """
  Fill nil Signal Theory fields on an Event with inferred values.

  Explicit (non-nil) fields are preserved.  Also computes signal_sn
  when absent.
  """
  @spec auto_classify(Event.t()) :: Event.t()
  def auto_classify(%Event{} = event) do
    dims = classify(event)

    event
    |> maybe_set(:signal_mode, dims.mode)
    |> maybe_set(:signal_genre, dims.genre)
    |> maybe_set(:signal_type, dims.type)
    |> maybe_set(:signal_format, dims.format)
    |> maybe_set(:signal_structure, dims.structure)
    |> maybe_set(:signal_sn, sn_ratio(event))
  end

  @doc """
  Compute the Signal-to-Noise ratio for an Event (0.0 – 1.0).

  Higher = more structured / contextualised signal.
  """
  @spec sn_ratio(Event.t()) :: float()
  def sn_ratio(%Event{} = event) do
    (dimension_score(event) * 0.4 + data_score(event) * 0.3 + context_score(event) * 0.3)
    |> Float.round(4)
  end

  # ---------------------------------------------------------------------------
  # Dimension inference (public so tests can verify each in isolation)
  # ---------------------------------------------------------------------------

  @doc "Infer the :mode dimension from the event."
  @spec infer_mode(Event.t()) :: atom()
  def infer_mode(%Event{data: data}) when is_map(data), do: :code
  def infer_mode(%Event{data: data}) when is_list(data), do: :code

  def infer_mode(%Event{data: data}) when is_binary(data) do
    if code_like?(data), do: :code, else: :linguistic
  end

  def infer_mode(%Event{}), do: :linguistic

  @doc "Infer the :genre dimension from the event type."
  @spec infer_genre(Event.t()) :: atom()
  def infer_genre(%Event{type: type}) do
    t = to_string(type)

    cond do
      String.contains?(t, "error") or String.contains?(t, "failure") -> :error
      String.contains?(t, "alert") or String.contains?(t, "algedonic") -> :alert
      String.contains?(t, "task") or String.contains?(t, "agent_task") -> :brief
      String.contains?(t, "spec") -> :spec
      String.contains?(t, "report") -> :report
      true -> :chat
    end
  end

  @doc "Infer the :type (speech act) dimension from the event type."
  @spec infer_type(Event.t()) :: atom()
  def infer_type(%Event{type: type}) do
    t = to_string(type)

    cond do
      String.ends_with?(t, "_completed") or String.ends_with?(t, "_done") or
        String.ends_with?(t, "_started") or String.ends_with?(t, "_response") ->
        :inform

      String.ends_with?(t, "_request") or String.ends_with?(t, "_dispatch") ->
        :direct

      String.ends_with?(t, "_approved") or String.ends_with?(t, "_committed") ->
        :commit

      String.ends_with?(t, "_decided") or String.ends_with?(t, "_rejected") ->
        :decide

      true ->
        :inform
    end
  end

  @doc "Infer the :format dimension from the event data."
  @spec infer_format(Event.t()) :: atom()
  def infer_format(%Event{data: data}) when is_map(data), do: :json
  def infer_format(%Event{data: data}) when is_list(data), do: :json

  def infer_format(%Event{data: data}) when is_binary(data) do
    cond do
      code_like?(data) -> :code
      markdown_like?(data) -> :markdown
      true -> :cli
    end
  end

  def infer_format(%Event{}), do: :cli

  @doc "Infer the :structure dimension from the event type."
  @spec infer_structure(Event.t()) :: atom()
  def infer_structure(%Event{type: type}) do
    t = to_string(type)

    cond do
      String.contains?(t, "error") or String.contains?(t, "failure") -> :error_report
      String.contains?(t, "alert") -> :alert_report
      String.contains?(t, "task") -> :brief
      true -> :default
    end
  end

  # ---------------------------------------------------------------------------
  # Scoring helpers (public for tests)
  # ---------------------------------------------------------------------------

  @doc "Score based on how many Signal dimensions are already set (0.0–1.0)."
  @spec dimension_score(Event.t()) :: float()
  def dimension_score(%Event{} = event) do
    fields = [:signal_mode, :signal_genre, :signal_type, :signal_format, :signal_structure]
    set = Enum.count(fields, fn f -> not is_nil(Map.get(event, f)) end)
    set / length(fields)
  end

  @doc "Score based on presence and richness of event data (0.0–1.0)."
  @spec data_score(Event.t()) :: float()
  def data_score(%Event{data: nil}), do: 0.0
  def data_score(%Event{data: ""}), do: 0.0
  def data_score(%Event{data: data}) when is_map(data) and map_size(data) == 0, do: 0.2
  def data_score(%Event{data: data}) when is_map(data), do: min(0.4 + map_size(data) * 0.1, 1.0)
  def data_score(%Event{data: data}) when is_binary(data), do: min(byte_size(data) / 500, 1.0)
  def data_score(%Event{data: data}) when is_list(data), do: min(length(data) * 0.1, 1.0)
  def data_score(%Event{}), do: 0.1

  @doc "Score based on contextual tracing fields (session_id, correlation_id, etc.) (0.0–1.0)."
  @spec context_score(Event.t()) :: float()
  def context_score(%Event{} = event) do
    fields = [:session_id, :correlation_id, :parent_id, :signal_sn]
    set = Enum.count(fields, fn f -> not is_nil(Map.get(event, f)) end)
    set / length(fields)
  end

  @doc "Returns true when the string looks like source code."
  @spec code_like?(String.t()) :: boolean()
  def code_like?(str) when is_binary(str) do
    Regex.match?(
      ~r/(defmodule|defp?\s|fn\s.*->|\|>|do\s*\n|end$|->|<-|=>|\blet\b|\bconst\b|\bvar\b|\bclass\b|\bfunction\b|:=|\bimport\b|\bexport\b|#\{)/m,
      str
    )
  end

  def code_like?(_), do: false

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @markdown_re ~r/(^#+\s|^\s*[-*+]\s|\*\*|__|\[.+\]\(.+\)|^\s*```)/m

  defp markdown_like?(str) do
    Regex.match?(@markdown_re, str)
  end

  defp maybe_set(event, _field, _value) when is_nil(event), do: event

  defp maybe_set(%Event{} = event, field, value) do
    if is_nil(Map.get(event, field)) do
      Map.put(event, field, value)
    else
      event
    end
  end
end
