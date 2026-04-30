defmodule OptimalSystemAgent.Agent.Loop.RenderBridge do
  @moduledoc """
  Wires `Tools.Behaviour.render/3` into the event bus.

  After every tool execution (success, error, or permission rejection) the
  bridge resolves the tool module from `:persistent_term`, derives the
  appropriate render stage, calls `LegacyAdapter.render/4`, and emits the
  resulting structured payload as a `:tool_render` event on `Events.Bus`.

  ## Stage mapping

    * `{:ok, content}` result   → `:tool_result` stage, payload = content
    * `{:error, msg}` result    → `:error` stage, payload = error string
    * `{:image, _, _, _}` result → `:tool_result` stage, payload = image tuple
    * Permission-blocked result  → `:rejected` stage, payload = block reason

  ## Fail-soft contract

  All paths are wrapped in `try/rescue/catch`. A crash in `render/3`, a nil
  return, or an unreachable Bus **never** propagates to the caller. Tool
  execution correctness is never compromised by render wiring.

  ## Bus emission

  Emits `Bus.emit(:tool_render, payload_map)` where `payload_map` is the map
  returned by the tool's `render/3` callback, merged with:

    * `:tool_name`   — string name of the tool
    * `:stage`       — render stage atom
    * `:session_id`  — forwarded from the executor state
  """

  require Logger

  alias OptimalSystemAgent.Tools.LegacyAdapter
  alias OptimalSystemAgent.Events.Bus

  @doc """
  Resolve the tool module, call render/3, and emit `:tool_render` on the Bus.

  `raw_result` is the value returned directly by the tool executor before
  normalization — one of:

    * `{:ok, content}` or `{:ok, content, metadata}`
    * `{:error, reason}`
    * `{:image, media_type, b64, path}`
    * A binary string (fallback result or permission block message)

  `session_id` is forwarded to the Bus payload as-is.
  """
  @spec emit(String.t(), any(), String.t() | nil) :: :ok
  def emit(tool_name, raw_result, session_id) do
    try do
      mod = lookup_module(tool_name)

      if mod == nil do
        :ok
      else
        {stage, payload} = stage_and_payload(raw_result)
        render_and_publish(mod, tool_name, stage, payload, session_id)
      end
    rescue
      e ->
        Logger.debug("[RenderBridge] render/3 skipped for #{tool_name}: #{Exception.message(e)}")
        :ok
    catch
      kind, reason ->
        Logger.debug("[RenderBridge] render/3 #{kind} for #{tool_name}: #{inspect(reason)}")
        :ok
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Look up the module from the persistent_term registry (lock-free reads).
  # Returns nil when the registry is not yet initialised or the tool is unknown
  # (e.g. a skill or MCP tool that has no render/3 callback).
  defp lookup_module(tool_name) do
    builtin_tools =
      :persistent_term.get(
        {OptimalSystemAgent.Tools.Registry, :builtin_tools},
        %{}
      )

    Map.get(builtin_tools, tool_name)
  end

  # Derive the render stage and unwrap the payload from the raw tool result.
  defp stage_and_payload({:ok, content}), do: {:tool_result, content}
  defp stage_and_payload({:ok, content, _meta}), do: {:tool_result, content}
  defp stage_and_payload({:error, reason}), do: {:error, to_string(reason)}
  defp stage_and_payload({:image, _mt, _b64, _p} = img), do: {:tool_result, img}

  defp stage_and_payload(binary) when is_binary(binary) do
    cond do
      String.starts_with?(binary, "Blocked:") -> {:rejected, binary}
      String.starts_with?(binary, "Error:") -> {:error, binary}
      true -> {:tool_result, binary}
    end
  end

  defp stage_and_payload(other), do: {:tool_result, other}

  # Call render/3 (fail-soft) then publish to the Bus.
  defp render_and_publish(mod, tool_name, stage, payload, session_id) do
    rendered =
      try do
        LegacyAdapter.render(mod, stage, payload, [])
      rescue
        e ->
          Logger.debug("[RenderBridge] #{inspect(mod)}.render/3 raised: #{Exception.message(e)}")
          nil
      catch
        kind, reason ->
          Logger.debug("[RenderBridge] #{inspect(mod)}.render/3 #{kind}: #{inspect(reason)}")
          nil
      end

    case rendered do
      nil ->
        :ok

      render_map when is_map(render_map) ->
        bus_payload =
          render_map
          |> Map.put(:tool_name, tool_name)
          |> Map.put(:stage, stage)
          |> Map.put(:session_id, session_id)

        try do
          Bus.emit(:tool_render, bus_payload)
        catch
          kind, reason ->
            Logger.debug(
              "[RenderBridge] Bus.emit failed for #{tool_name}: #{kind} #{inspect(reason)}"
            )
        end

        :ok

      other ->
        Logger.debug(
          "[RenderBridge] #{inspect(mod)}.render/3 returned unexpected value: #{inspect(other)}"
        )

        :ok
    end
  end
end
