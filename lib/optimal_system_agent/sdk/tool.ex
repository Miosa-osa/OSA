defmodule OptimalSystemAgent.SDK.Tool do
  @moduledoc """
  Define custom tools via closures for the SDK.

  Generates a dynamic module implementing `Tools.Behaviour` and registers it
  with `Tools.Registry`. The handler closure is stored in `:persistent_term`
  for lock-free execution.

  ## Example

      OptimalSystemAgent.SDK.Tool.define(
        "weather",
        "Get current weather for a city",
        %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["city"]
        },
        fn %{"city" => city} ->
          {:ok, "Weather in \#{city}: 72°F, sunny"}
        end
      )
  """

  alias OptimalSystemAgent.Tools.Registry, as: Tools

  @doc """
  Define and register a custom tool.

  Creates a dynamic module implementing `Tools.Behaviour` backed by the
  given closure. The module is compiled into the BEAM VM and registered
  with the Tools.Registry (which triggers goldrush recompilation).

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec define(String.t(), String.t(), map(), (map() -> {:ok, String.t()} | {:error, String.t()})) ::
          :ok | {:error, term()}
  def define(name, description, parameters, handler) when is_function(handler, 1) do
    # Store handler in persistent_term for lock-free execution
    handler_key = {__MODULE__, :handler, name}
    :persistent_term.put(handler_key, handler)

    # Generate a unique module name
    module_name = Module.concat([OptimalSystemAgent.SDK.Tools, Macro.camelize(name)])

    # Define the module dynamically
    contents =
      quote do
        @behaviour OptimalSystemAgent.Tools.Behaviour

        @impl true
        def name, do: unquote(name)

        @impl true
        def description, do: unquote(description)

        @impl true
        def parameters, do: unquote(Macro.escape(parameters))

        @impl true
        def execute(args) do
          handler = :persistent_term.get({OptimalSystemAgent.SDK.Tool, :handler, unquote(name)})
          handler.(args)
        end
      end

    # Compile the module
    case Module.create(module_name, contents, Macro.Env.location(__ENV__)) do
      {:module, mod, _binary, _} ->
        # Register with Tools.Registry
        Tools.register(mod)

      error ->
        {:error, {:module_creation_failed, error}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Undefine a previously defined SDK tool.

  Removes the handler from `:persistent_term`. The tool will still exist in
  the Tools.Registry until the next recompilation, but calls will fail
  with a missing handler error.
  """
  @spec undefine(String.t()) :: :ok
  def undefine(name) do
    handler_key = {__MODULE__, :handler, name}

    try do
      :persistent_term.erase(handler_key)
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  @doc """
  Build a tool definition map (for LLM function calling) without registering.

  Useful for passing extra tools via the `:extra_tools` option to the Loop.
  """
  @spec build_tool_def(String.t(), String.t(), map()) :: map()
  def build_tool_def(name, description, parameters) do
    %{
      name: name,
      description: description,
      parameters: parameters
    }
  end
end
