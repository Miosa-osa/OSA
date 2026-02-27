defmodule OptimalSystemAgent.Providers.Behaviour do
  @moduledoc """
  Behaviour that every LLM provider module must implement.

  Each provider is responsible for:
  - Formatting outbound messages into its own API format
  - Parsing inbound responses into the canonical shape
  - Handling tool calls (format outbound, parse inbound)
  - Reading its own config from Application environment

  Canonical response shape:
    {:ok, %{content: String.t(), tool_calls: list(tool_call())}}

  where tool_call() is:
    %{id: String.t(), name: String.t(), arguments: map()}
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}
  @type chat_result :: {:ok, %{content: String.t(), tool_calls: list(tool_call())}} | {:error, String.t()}

  @doc "Send a chat completion request. Returns canonical response."
  @callback chat(messages :: list(message()), opts :: keyword()) :: chat_result()

  @doc "Return the canonical atom name for this provider (e.g. :groq)."
  @callback name() :: atom()

  @doc "Return the default model string for this provider."
  @callback default_model() :: String.t()
end
