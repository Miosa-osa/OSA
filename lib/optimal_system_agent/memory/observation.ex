defmodule OptimalSystemAgent.Memory.Observation do
  @moduledoc """
  Immutable observation record for the SICA learning engine.

  An `Observation` captures a single tool invocation or correction event.
  It is appended to the `:osa_learning` ETS table by
  `OptimalSystemAgent.Memory.Learning` and consumed by
  `OptimalSystemAgent.Memory.Consolidator`.

  ## Fields

  * `id`            — unique monotonic identifier (nanoseconds)
  * `type`          — `:success | :failure | :correction`
  * `tool_name`     — name of the invoked tool
  * `error_message` — error string (failures only, otherwise `nil`)
  * `duration_ms`   — wall-clock time in ms (optional)
  * `context`       — arbitrary ambient metadata map
  * `recorded_at`   — UTC timestamp
  """

  @type obs_type :: :success | :failure | :correction

  @type t :: %__MODULE__{
          id: integer(),
          type: obs_type(),
          tool_name: String.t(),
          error_message: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          context: map(),
          recorded_at: DateTime.t()
        }

  defstruct [
    :id,
    :type,
    :tool_name,
    :error_message,
    :duration_ms,
    :recorded_at,
    context: %{}
  ]

  @valid_types [:success, :failure, :correction]

  @doc """
  Build a new `Observation` from an attribute map. Returns `{:ok, obs}` or
  `{:error, reason}`.

  The `:type` key is required and must be one of `:success`, `:failure`,
  `:correction`. `:tool_name` defaults to `"unknown"` when absent.
  """
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    type = Map.get(attrs, :type) || Map.get(attrs, "type")

    with {:ok, validated_type} <- validate_type(type) do
      obs = %__MODULE__{
        id: System.monotonic_time(:nanosecond),
        type: validated_type,
        tool_name:
          to_string(Map.get(attrs, :tool_name) || Map.get(attrs, "tool_name") || "unknown"),
        error_message:
          string_or_nil(Map.get(attrs, :error_message) || Map.get(attrs, "error_message")),
        duration_ms: Map.get(attrs, :duration_ms) || Map.get(attrs, "duration_ms"),
        context: Map.get(attrs, :context) || Map.get(attrs, "context") || %{},
        recorded_at: DateTime.utc_now()
      }

      {:ok, obs}
    end
  end

  def new(_), do: {:error, "observation attributes must be a map"}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_type(type) when type in @valid_types, do: {:ok, type}

  defp validate_type(type) when is_binary(type) do
    atom = String.to_existing_atom(type)

    if atom in @valid_types do
      {:ok, atom}
    else
      {:error,
       "invalid observation type: #{inspect(type)}. Must be one of #{inspect(@valid_types)}"}
    end
  rescue
    ArgumentError ->
      {:error,
       "invalid observation type: #{inspect(type)}. Must be one of #{inspect(@valid_types)}"}
  end

  defp validate_type(type),
    do:
      {:error,
       "invalid observation type: #{inspect(type)}. Must be one of #{inspect(@valid_types)}"}

  defp string_or_nil(nil), do: nil
  defp string_or_nil(s) when is_binary(s), do: s
  defp string_or_nil(other), do: to_string(other)
end
