defmodule OptimalSystemAgent.Tools.Behaviour do
  @moduledoc """
  Behaviour contract for OSA tools.

  Any module that implements this behaviour becomes a registered tool in
  `OptimalSystemAgent.Tools.Registry`.

  ## Required callbacks

    * `name/0`        — unique snake_case identifier string (e.g. `"file_read"`)
    * `description/0` — one-sentence description for the LLM
    * `parameters/0`  — JSON Schema object map describing accepted parameters
    * `execute/1`     — receives the parsed params map, returns `{:ok, result}` or `{:error, reason}`

  ## Optional callbacks

    * `safety/0`    — safety tier, one of `:read_only | :write_safe | :write_destructive | :terminal`
    * `available?/0` — runtime gate; returning `false` hides the tool from the LLM

  ## Example

  ```elixir
  defmodule MyApp.Tools.Greet do
    @behaviour OptimalSystemAgent.Tools.Behaviour

    @impl true
    def name, do: "greet"

    @impl true
    def description, do: "Greet a user by name."

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "Name to greet"}
        },
        "required" => ["name"]
      }
    end

    @impl true
    def execute(%{"name" => n}), do: {:ok, "Hello, \#{n}!"}
    def execute(_), do: {:error, "Missing required parameter: name"}
  end
  ```
  """

  @doc "Unique snake_case tool identifier."
  @callback name() :: String.t()

  @doc "One-sentence tool description for the LLM."
  @callback description() :: String.t()

  @doc "JSON Schema object describing accepted parameters."
  @callback parameters() :: map()

  @doc "Execute the tool with the given params map."
  @callback execute(params :: map()) :: {:ok, any()} | {:error, String.t()}

  @doc "Safety tier for risk classification."
  @callback safety() :: :read_only | :write_safe | :write_destructive | :terminal

  @doc "Runtime availability gate. Return `false` to hide the tool from the LLM."
  @callback available?() :: boolean()

  @doc "Deferred loading gate. Return `true` to exclude from system prompt (discoverable via tool_search)."
  @callback deferred?() :: boolean()

  @doc "Concurrency safety flag. Return `true` if this tool can safely run in parallel with others. Default: true."
  @callback concurrent?() :: boolean()

  @optional_callbacks safety: 0, available?: 0, deferred?: 0, concurrent?: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour OptimalSystemAgent.Tools.Behaviour
    end
  end
end
