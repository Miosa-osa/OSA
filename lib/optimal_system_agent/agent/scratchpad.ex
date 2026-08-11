defmodule OptimalSystemAgent.Agent.Scratchpad do
  @moduledoc """
  Provider-agnostic thinking/scratchpad support.

  For Anthropic: uses native extended thinking (no-op here).
  For all other providers: injects a `<think>` prompt instruction into the
  system message and parses `<think>...</think>` blocks out of responses.

  Extracted thinking is:
    - Removed from the displayed response text
    - Emitted as `:thinking_captured` bus events for the learning engine
    - Emitted as `:thinking_delta` system events for TUI display
  """

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Agent.Trajectory

  @think_instruction """
  ## Private Reasoning

  Before responding or taking actions, reason step-by-step inside \
  <think>...</think> tags. Use this space to:
  - Analyze the request and break it into sub-problems
  - Consider edge cases, risks, and alternative approaches
  - Plan your tool calls before executing them
  - Reflect on previous results before deciding next steps

  Content inside <think> tags is captured for learning but NOT shown to the user. \
  Your visible response should contain only the final answer or action — never the \
  reasoning process.
  """

  # Regex to match <think>...</think> blocks (including multiline).
  # Captures the inner content. Uses dotall via the `s` flag.
  @think_pattern ~r/<think>(.*?)<\/think>/s

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns true if scratchpad injection should be used for the given provider.

  Scratchpad is used when:
    1. `:scratchpad_enabled` config is true (default: true)
    2. Provider is NOT Anthropic (Anthropic uses native extended thinking)
  """
  @spec inject?(atom()) :: boolean()
  def inject?(provider) do
    enabled = Application.get_env(:optimal_system_agent, :scratchpad_enabled, true)
    enabled and provider != :anthropic
  end

  @doc """
  Returns the scratchpad system instruction to inject into the prompt.
  Only call this when `inject?/1` returns true.
  """
  @spec instruction() :: String.t()
  def instruction, do: @think_instruction

  @doc """
  Extracts `<think>...</think>` blocks from response text.

  Returns `{clean_text, thinking_parts}` where:
    - `clean_text` is the response with all `<think>` blocks removed
    - `thinking_parts` is a list of extracted thinking strings
  """
  @spec extract(String.t() | nil) :: {String.t(), [String.t()]}
  def extract(nil), do: {"", []}
  def extract(""), do: {"", []}

  def extract(text) when is_binary(text) do
    thinking_parts =
      @think_pattern
      |> Regex.scan(text)
      |> Enum.flat_map(fn
        [_full, inner] when is_binary(inner) -> [String.trim(inner)]
        _ -> []
      end)
      |> Enum.reject(&(&1 == ""))

    clean_text =
      text
      |> String.replace(@think_pattern, "")
      |> String.replace(~r/\n{3,}/, "\n\n")
      |> String.trim()

    {clean_text, thinking_parts}
  end

  @doc """
  Processes an LLM response: extracts thinking, emits events, returns clean text.

  This is the main entry point called from the agent loop after receiving
  a response from a non-Anthropic provider.
  """
  @spec process_response(String.t() | nil, String.t()) :: String.t()
  def process_response(text, session_id) do
    {clean_text, thinking_parts} = extract(text)

    if thinking_parts != [] do
      # Same rule as the streaming `:thinking_delta` path in Loop.LLMClient:
      # reasoning quotes file contents verbatim, and both events below end up
      # on screen or on disk. Redact before either emission.
      combined_thinking =
        thinking_parts |> Enum.join("\n\n---\n\n") |> Trajectory.redact()

      # Emit thinking delta for TUI display
      Bus.emit(:system_event, %{
        event: :thinking_delta,
        session_id: session_id,
        text: combined_thinking
      })

      # Emit thinking_captured for learning engine
      Bus.emit(:system_event, %{
        event: :thinking_captured,
        session_id: session_id,
        text: combined_thinking
      })
    end

    clean_text
  end
end
