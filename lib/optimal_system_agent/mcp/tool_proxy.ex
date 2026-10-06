defmodule OptimalSystemAgent.MCP.ToolProxy do
  @moduledoc """
  Dynamically creates tool proxy modules for MCP server tools.

  When an MCP client discovers tools via `tools/list`, this module creates
  a runtime Elixir module for each tool that implements `Tools.Behaviour`.
  Each proxy module routes `execute/1` calls through the MCP client as
  JSON-RPC `tools/call` requests.

  Proxy modules are named: `OptimalSystemAgent.MCP.ToolProxy.<ServerName>_<ToolName>`
  (e.g., `OptimalSystemAgent.MCP.ToolProxy.Sorx_signal_process`)

  Registered with `Tools.Registry` on discovery so they appear in the
  LLM tool list alongside built-in tools.
  """
  require Logger

  alias OptimalSystemAgent.Tools.Registry, as: ToolRegistry

  @doc """
  Register proxy tools for all tools discovered from an MCP server.

  Creates a dynamic module for each tool and registers it with Tools.Registry.
  """
  @spec register_tools(String.t(), list(map())) :: :ok
  def register_tools(server_name, tools) when is_list(tools) do
    Enum.each(tools, fn tool_def ->
      case create_proxy_module(server_name, tool_def) do
        {:ok, module} ->
          ToolRegistry.register(module)
          Logger.info("[MCP.ToolProxy] Registered proxy: #{module.name()}")

        {:error, reason} ->
          Logger.warning("[MCP.ToolProxy] Failed to create proxy for #{inspect(tool_def)}: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Unregister all proxy tools for a given MCP server.

  Useful when an MCP server disconnects and its tools should be removed.
  """
  @spec unregister_tools(String.t(), list(map())) :: :ok
  def unregister_tools(_server_name, _tools) do
    # Tools.Registry doesn't support unregister yet — tools remain until restart.
    # This is a placeholder for future implementation.
    :ok
  end

  # --- Private Functions ---

  defp create_proxy_module(server_name, tool_def) do
    tool_name = tool_def["name"]

    unless is_binary(tool_name) and tool_name != "" do
      {:error, :invalid_tool_name}
    else
      module_name = build_module_name(server_name, tool_name)
      description = tool_def["description"] || "MCP tool: #{tool_name}"
      input_schema = normalize_schema(tool_def["inputSchema"])
      # Prefix the tool name with the server name to avoid collisions
      prefixed_name = "mcp_#{server_name}_#{tool_name}"

      # Capture values for the module closure
      captured_server = server_name
      captured_tool = tool_name
      captured_desc = description
      captured_schema = input_schema
      captured_prefixed = prefixed_name

      # Create the module at runtime
      contents =
        quote do
          @behaviour OptimalSystemAgent.Tools.Behaviour

          @impl true
          def name, do: unquote(captured_prefixed)

          @impl true
          def description, do: unquote(captured_desc)

          @impl true
          def parameters, do: unquote(Macro.escape(captured_schema))

          @impl true
          def execute(args) do
            case OptimalSystemAgent.MCP.Client.call_tool(
                   unquote(captured_server),
                   unquote(captured_tool),
                   args
                 ) do
              {:ok, result} ->
                format_result(result)

              {:error, %{"message" => msg}} ->
                {:error, msg}

              {:error, reason} ->
                {:error, inspect(reason)}
            end
          end

          @impl true
          def available? do
            OptimalSystemAgent.MCP.Client.initialized?(unquote(captured_server))
          rescue
            _ -> false
          catch
            :exit, _ -> false
          end

          defp format_result(result) when is_map(result) do
            case result do
              %{"content" => content} when is_list(content) ->
                text =
                  content
                  |> Enum.filter(fn item -> item["type"] == "text" end)
                  |> Enum.map_join("\n", fn item -> item["text"] || "" end)

                if text == "" do
                  {:ok, Jason.encode!(result)}
                else
                  {:ok, text}
                end

              %{"content" => content} when is_binary(content) ->
                {:ok, content}

              _ ->
                {:ok, Jason.encode!(result)}
            end
          end

          defp format_result(result) when is_binary(result) do
            {:ok, result}
          end

          defp format_result(result) do
            {:ok, inspect(result)}
          end
        end

      Module.create(module_name, contents, Macro.Env.location(__ENV__))
      {:ok, module_name}
    end
  rescue
    e ->
      {:error, e}
  end

  defp build_module_name(server_name, tool_name) do
    # Sanitize names for valid Elixir module segments
    server_part = camelize(server_name)
    tool_part = camelize(tool_name)

    Module.concat([OptimalSystemAgent.MCP.ToolProxy, "#{server_part}_#{tool_part}"])
  end

  defp camelize(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.split("_", trim: true)
    |> Enum.map_join(&String.capitalize/1)
  end

  defp normalize_schema(nil) do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => []
    }
  end

  defp normalize_schema(schema) when is_map(schema) do
    schema
    |> Map.put_new("type", "object")
    |> Map.put_new("properties", %{})
    |> Map.put_new("required", [])
  end
end
