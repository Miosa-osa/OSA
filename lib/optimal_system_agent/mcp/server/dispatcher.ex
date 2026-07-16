defmodule OptimalSystemAgent.MCP.Server.Dispatcher do
  @moduledoc """
  Pure(ish) request router for the OSA MCP *server*.

  Maps inbound MCP JSON-RPC methods onto OSA capabilities:

    * `initialize`                 → serverInfo/capabilities handshake
    * `notifications/initialized`  → no response (notification)
    * `tools/list`                 → OSA tools via `Tools.Registry.list_tools_direct/0`
                                     plus the built-in `osa_ask` agent tool
    * `tools/call`                 → `Tools.Registry.execute/2`, or the agent
                                     loop for `osa_ask`

  `dispatch/1` takes a decoded JSON-RPC request tuple (from
  `Protocol.JSONRPC.decode/1`) and returns `{:reply, response_map}` or
  `:noreply` (for notifications). The only side effects are the tool execution
  itself and, for `osa_ask`, running an agent loop.
  """

  require Logger

  alias OptimalSystemAgent.MCP.Protocol.JSONRPC
  alias OptimalSystemAgent.Tools.Registry, as: Tools

  @protocol_version "2024-11-05"
  @server_info %{"name" => "osa", "version" => "1.0.0"}
  @agent_tool "osa_ask"

  # JSON-RPC error codes.
  @method_not_found -32601
  @internal_error -32603

  @doc "Dispatch a decoded JSON-RPC message. See module doc."
  @spec dispatch(tuple()) :: {:reply, map()} | :noreply
  def dispatch({:request, id, method, params}), do: handle(method, params, id)
  def dispatch({:notification, _method, _params}), do: :noreply
  def dispatch({:response, _id, _result}), do: :noreply
  def dispatch({:error, _id, _err}), do: :noreply

  # ── Method handlers ───────────────────────────────────────────────────

  defp handle("initialize", _params, id) do
    result = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => @server_info
    }

    {:reply, JSONRPC.response(id, result)}
  end

  defp handle("notifications/initialized", _params, _id), do: :noreply
  defp handle("initialized", _params, _id), do: :noreply

  defp handle("ping", _params, id), do: {:reply, JSONRPC.response(id, %{})}

  defp handle("tools/list", _params, id) do
    tools = osa_tools() ++ [agent_tool_schema()]
    {:reply, JSONRPC.response(id, %{"tools" => tools})}
  end

  defp handle("tools/call", params, id) do
    name = params["name"]
    arguments = params["arguments"] || %{}

    result =
      cond do
        name == @agent_tool -> run_agent(arguments)
        is_binary(name) -> Tools.execute(name, arguments)
        true -> {:error, "missing tool name"}
      end

    {:reply, JSONRPC.response(id, to_mcp_result(result))}
  rescue
    e ->
      {:reply, JSONRPC.error_response(id, @internal_error, Exception.message(e))}
  end

  defp handle(method, _params, id) do
    {:reply, JSONRPC.error_response(id, @method_not_found, "Method not found: #{method}")}
  end

  # ── OSA tool listing ──────────────────────────────────────────────────

  defp osa_tools do
    Tools.list_tools_direct()
    |> Enum.map(fn tool ->
      %{
        "name" => tool.name,
        "description" => Map.get(tool, :description, ""),
        "inputSchema" => Map.get(tool, :parameters, %{"type" => "object", "properties" => %{}})
      }
    end)
  rescue
    _ -> []
  end

  defp agent_tool_schema do
    %{
      "name" => @agent_tool,
      "description" =>
        "Ask the OSA agent to accomplish a task using its full tool set and reasoning loop. " <>
          "Returns the agent's final response.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "prompt" => %{
            "type" => "string",
            "description" => "The task or question for the OSA agent."
          }
        },
        "required" => ["prompt"]
      }
    }
  end

  # ── Agent loop (osa_ask) ──────────────────────────────────────────────

  defp run_agent(%{} = arguments) do
    prompt = arguments["prompt"] || arguments[:prompt]

    if is_binary(prompt) and prompt != "" do
      session_id = "mcp_server_#{System.unique_integer([:positive])}"

      loop_opts = [session_id: session_id, channel: :headless]

      case DynamicSupervisor.start_child(
             OptimalSystemAgent.SessionSupervisor,
             {OptimalSystemAgent.Agent.Loop, loop_opts}
           ) do
        {:ok, _pid} ->
          OptimalSystemAgent.Agent.Loop.process_message(session_id, prompt)

        {:error, reason} ->
          {:error, "failed to start agent session: #{inspect(reason)}"}
      end
    else
      {:error, "osa_ask requires a non-empty 'prompt'"}
    end
  end

  # ── OSA result → MCP result ───────────────────────────────────────────

  # Convert OSA's tool-result shape into an MCP tools/call result map.
  defp to_mcp_result({:ok, {:image, %{media_type: mt, data: data, path: _path}}}) do
    %{"content" => [%{"type" => "image", "data" => data, "mimeType" => mt}], "isError" => false}
  end

  defp to_mcp_result({:ok, content, _metadata}) do
    text_result(content)
  end

  defp to_mcp_result({:ok, content}), do: text_result(content)

  defp to_mcp_result({:error, reason}) do
    %{"content" => [%{"type" => "text", "text" => error_text(reason)}], "isError" => true}
  end

  defp to_mcp_result(other), do: text_result(other)

  defp text_result(content) do
    %{"content" => [%{"type" => "text", "text" => to_text(content)}], "isError" => false}
  end

  defp to_text(content) when is_binary(content), do: content
  defp to_text(content), do: inspect(content)

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
