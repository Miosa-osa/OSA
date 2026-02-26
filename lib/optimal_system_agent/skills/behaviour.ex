defmodule OptimalSystemAgent.Skills.Behaviour do
  @moduledoc """
  Behaviour for implementing agent skills.

  Every skill implements four callbacks:
  - `name/0` — unique tool name (string)
  - `description/0` — human-readable description for the LLM
  - `parameters/0` — JSON Schema for tool arguments
  - `execute/1` — runs the tool with validated arguments

  ## Example

      defmodule MyApp.Skills.Calculator do
        @behaviour OptimalSystemAgent.Skills.Behaviour

        @impl true
        def name, do: "calculator"

        @impl true
        def description, do: "Evaluate a math expression"

        @impl true
        def parameters do
          %{
            "type" => "object",
            "properties" => %{
              "expression" => %{"type" => "string", "description" => "Math expression to evaluate"}
            },
            "required" => ["expression"]
          }
        end

        @impl true
        def execute(%{"expression" => expr}) do
          {result, _} = Code.eval_string(expr)
          {:ok, "\#{result}"}
        end
      end

  Register at runtime — goldrush recompiles the dispatcher automatically:

      OptimalSystemAgent.Skills.Registry.register(MyApp.Skills.Calculator)

  ## Hot Code Reload

  Because goldrush recompiles the tool dispatcher module on every `register/1`
  call, new skills become available immediately without restarting the BEAM VM.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(args :: map()) :: {:ok, String.t()} | {:error, String.t()}
end
