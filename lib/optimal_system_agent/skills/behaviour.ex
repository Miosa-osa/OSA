defmodule OptimalSystemAgent.Skills.Behaviour do
  @moduledoc """
  Behaviour for implementing agent skills.

  Every skill implements four callbacks:
  - `name/0` — unique tool name (string)
  - `description/0` — human-readable description for the LLM
  - `parameters/0` — JSON Schema for tool arguments
  - `execute/1` — runs the tool with validated arguments

  ## Example

      defmodule MyApp.Skills.WordCount do
        @behaviour OptimalSystemAgent.Skills.Behaviour

        @impl true
        def name, do: "word_count"

        @impl true
        def description, do: "Count words in a text string"

        @impl true
        def parameters do
          %{
            "type" => "object",
            "properties" => %{
              "text" => %{"type" => "string", "description" => "Text to count words in"}
            },
            "required" => ["text"]
          }
        end

        @impl true
        def execute(%{"text" => text}) do
          count = text |> String.split(~r/\\s+/, trim: true) |> length()
          {:ok, "\#{count} words"}
        end
      end

  > **Security:** NEVER use `Code.eval_string/1` on user-supplied input in skills.
  > All arguments arrive from untrusted sources (LLM output or user messages).

  Register at runtime — goldrush recompiles the dispatcher automatically:

      OptimalSystemAgent.Skills.Registry.register(MyApp.Skills.WordCount)

  ## Hot Code Reload

  Because goldrush recompiles the tool dispatcher module on every `register/1`
  call, new skills become available immediately without restarting the BEAM VM.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(args :: map()) :: {:ok, String.t()} | {:error, String.t()}
end
