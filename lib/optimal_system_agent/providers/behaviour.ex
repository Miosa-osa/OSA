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
  @type chat_result ::
          {:ok, %{content: String.t(), tool_calls: list(tool_call())}} | {:error, String.t()}

  @doc "Send a chat completion request. Returns canonical response."
  @callback chat(messages :: list(message()), opts :: keyword()) :: chat_result()

  @doc """
  Stream a chat completion request, invoking callback with deltas.

  The callback receives tuples:
    - `{:text_delta, text}` — incremental text chunk
    - `{:tool_use_start, %{id: String.t(), name: String.t()}}` — tool call begins
    - `{:tool_use_delta, json_chunk}` — incremental tool call JSON
    - `{:done, %{content: String.t(), tool_calls: list(tool_call())}}` — stream complete

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback chat_stream(messages :: list(message()), callback :: function(), opts :: keyword()) ::
              :ok | {:error, String.t()}

  @doc "Return the canonical atom name for this provider (e.g. :groq)."
  @callback name() :: atom()

  @doc "Return the default model string for this provider."
  @callback default_model() :: String.t()

  @optional_callbacks [chat_stream: 3]
end
