defmodule OptimalSystemAgent.Events.FailureModes do
  @moduledoc "Signal Theory failure mode detection for Event structs."

  @type failure_mode ::
          :routing_failure
          | :bandwidth_overload
          | :fidelity_failure
          | :genre_mismatch
          | :variety_failure
          | :structure_failure
          | :bridge_failure
          | :herniation_failure
          | :decay_failure
          | :feedback_failure
          | :adversarial_noise

  @signal_dimensions [
    :signal_mode,
    :signal_genre,
    :signal_type,
    :signal_format,
    :signal_structure
  ]

  @doc "Detect all Signal Theory failure modes present in the event. Returns a list of {mode_atom, description} tuples."
  @spec detect(struct()) :: [{failure_mode(), String.t()}]
  def detect(event) do
    []
    |> check_routing_failure(event)
    |> check_bandwidth_overload(event)
    |> check_fidelity_failure(event)
    |> check_variety_failure(event)
    |> check_structure_failure(event)
    |> check_genre_mismatch(event)
    |> check_herniation_failure(event)
    |> check_bridge_failure(event)
    |> check_decay_failure(event)
    |> check_feedback_failure(event)
    |> check_adversarial_noise(event)
  end

  @doc "Check one specific failure mode. Returns :ok or {:violation, mode, description}."
  @spec check(struct(), failure_mode()) :: :ok | {:violation, failure_mode(), String.t()}
  def check(event, mode) do
    failures = detect(event)

    case Enum.find(failures, fn {m, _} -> m == mode end) do
      {^mode, desc} -> {:violation, mode, desc}
      nil -> :ok
    end
  end

  # Shannon violations

  defp check_routing_failure(acc, %{source: nil}) do
    [{:routing_failure, "Event has no source — routing is impossible"} | acc]
  end

  defp check_routing_failure(acc, _event), do: acc

  defp check_bandwidth_overload(acc, event) do
    size = byte_size(inspect(event.data, limit: :infinity, printable_limit: :infinity))

    if size > 100_000 do
      [
        {:bandwidth_overload,
         "Event data exceeds bandwidth limit: #{size} bytes (limit: 100,000)"}
        | acc
      ]
    else
      acc
    end
  end

  defp check_fidelity_failure(acc, %{signal_sn: sn}) when is_number(sn) and sn < 0.3 do
    [{:fidelity_failure, "Signal S/N ratio #{sn} is below acceptable threshold of 0.3"} | acc]
  end

  defp check_fidelity_failure(acc, _event), do: acc

  # Ashby violations

  defp check_variety_failure(acc, event) do
    set_count = Enum.count(@signal_dimensions, &(Map.get(event, &1) != nil))

    if set_count == 0 do
      [{:variety_failure, "No signal dimensions are classified — Signal variety is zero"} | acc]
    else
      acc
    end
  end

  defp check_structure_failure(acc, event) do
    set_count = Enum.count(@signal_dimensions, &(Map.get(event, &1) != nil))

    if set_count > 0 and set_count < length(@signal_dimensions) do
      [
        {:structure_failure,
         "Partial signal classification: #{set_count}/#{length(@signal_dimensions)} dimensions set"}
        | acc
      ]
    else
      acc
    end
  end

  defp check_genre_mismatch(acc, %{signal_genre: nil}), do: acc

  defp check_genre_mismatch(acc, event) do
    inferred = infer_genre(event.type)

    if inferred != :chat and event.signal_genre != inferred do
      [
        {:genre_mismatch,
         "Declared genre :#{event.signal_genre} contradicts inferred genre :#{inferred} from event type #{inspect(event.type)}"}
        | acc
      ]
    else
      acc
    end
  end

  defp infer_genre(type) when is_atom(type) do
    str = Atom.to_string(type)

    if String.contains?(str, ["error", "fail", "crash"]) do
      :incident
    else
      :chat
    end
  end

  defp infer_genre(_), do: :chat

  # Beer violations

  defp check_herniation_failure(acc, %{parent_id: parent_id, correlation_id: nil})
       when not is_nil(parent_id) do
    [
      {:herniation_failure,
       "Event has parent_id #{inspect(parent_id)} but no correlation_id — structural context is broken"}
      | acc
    ]
  end

  defp check_herniation_failure(acc, _event), do: acc

  defp check_bridge_failure(acc, event) do
    ext_count = map_size(event.extensions || %{})

    if ext_count > 20 do
      [
        {:bridge_failure,
         "Extensions map has #{ext_count} keys (limit: 20) — shared context exceeds channel capacity"}
        | acc
      ]
    else
      acc
    end
  end

  defp check_decay_failure(acc, event) do
    age_seconds = DateTime.diff(DateTime.utc_now(), event.time, :second)

    if age_seconds > 86_400 do
      [
        {:decay_failure,
         "Event is #{age_seconds}s old (limit: 86,400s / 24h) — Signal has decayed"}
        | acc
      ]
    else
      acc
    end
  end

  # Wiener violations

  defp check_feedback_failure(acc, %{signal_type: :direct, correlation_id: nil}) do
    [
      {:feedback_failure, "Direct signal has no correlation_id — feedback loop cannot close"}
      | acc
    ]
  end

  defp check_feedback_failure(acc, _event), do: acc

  # Adversarial noise

  defp check_adversarial_noise(acc, event) do
    ext_count = map_size(event.extensions || %{})

    if ext_count > 50 do
      [
        {:adversarial_noise,
         "Extensions map has #{ext_count} keys (threshold: 50) — possible adversarial noise injection"}
        | acc
      ]
    else
      acc
    end
  end
end
