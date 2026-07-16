defmodule OptimalSystemAgent.Observability.OTel do
  @moduledoc """
  OpenTelemetry GenAI-convention adapter seam (primitive #30).

  OSA does not depend on an OTLP exporter today, so this module defines a clean
  adapter behaviour plus a no-op default. GenAI spans/attributes can be emitted
  from the agent loop without any hard dependency; wiring a real exporter is a
  drop-in config change — no call sites move.

      config :optimal_system_agent,
        otel_enabled: true,
        otel_adapter: MyApp.OTelExporter

  Adapters receive an operation atom and an already-built attribute map that
  follows the OpenTelemetry semantic conventions for Generative AI:

    * `gen_ai.operation.name`   — "chat" | "execute_tool" | "turn"
    * `gen_ai.request.model`
    * `gen_ai.conversation.id`
    * `gen_ai.tool.name`
    * `gen_ai.usage.input_tokens`
    * `gen_ai.usage.output_tokens`

  Emission is off by default (`otel_enabled: false`) and is always best-effort —
  an adapter crash can never take down the caller.
  """

  @callback on_gen_ai(operation :: atom(), attributes :: map()) :: :ok

  @default_adapter OptimalSystemAgent.Observability.OTel.Noop

  @doc "Whether OTLP GenAI export is enabled (default: false)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:optimal_system_agent, :otel_enabled, false) == true

  @doc "The configured adapter module (default: the no-op adapter)."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:optimal_system_agent, :otel_adapter, @default_adapter)

  @doc """
  Forward a GenAI operation + attribute map to the configured adapter.

  A no-op unless `otel_enabled: true`. Never raises — adapter failures are
  swallowed so telemetry can never break the agent loop.
  """
  @spec emit(atom(), map()) :: :ok
  def emit(operation, attributes) when is_atom(operation) and is_map(attributes) do
    if enabled?() do
      try do
        adapter().on_gen_ai(operation, attributes)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  @doc """
  Build a GenAI-semantic-convention attribute map from loose keyword opts.

  Only non-nil values are included. A `:usage` map (the normalized usage shape
  from `Loop.Accounting`) expands into `gen_ai.usage.input_tokens` /
  `gen_ai.usage.output_tokens`.

  ## Options

    * `:operation`       → `gen_ai.operation.name`
    * `:model`           → `gen_ai.request.model`
    * `:conversation_id` → `gen_ai.conversation.id`
    * `:tool_name`       → `gen_ai.tool.name`
    * `:usage`           → `gen_ai.usage.*`
  """
  @spec gen_ai_attributes(keyword()) :: map()
  def gen_ai_attributes(opts) when is_list(opts) do
    %{}
    |> put("gen_ai.operation.name", opts[:operation])
    |> put("gen_ai.request.model", opts[:model])
    |> put("gen_ai.conversation.id", opts[:conversation_id])
    |> put("gen_ai.tool.name", opts[:tool_name])
    |> put_usage(opts[:usage])
  end

  # --- Private ---

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, stringish(value))

  defp stringish(v) when is_atom(v), do: Atom.to_string(v)
  defp stringish(v), do: v

  defp put_usage(map, usage) when is_map(usage) do
    map
    |> maybe_put_int("gen_ai.usage.input_tokens", usage_val(usage, :input_tokens))
    |> maybe_put_int("gen_ai.usage.output_tokens", usage_val(usage, :output_tokens))
  end

  defp put_usage(map, _), do: map

  defp usage_val(usage, key), do: Map.get(usage, key) || Map.get(usage, Atom.to_string(key))

  defp maybe_put_int(map, _key, val) when not is_integer(val), do: map
  defp maybe_put_int(map, key, val), do: Map.put(map, key, val)
end
