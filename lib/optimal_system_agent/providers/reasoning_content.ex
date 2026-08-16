defmodule OptimalSystemAgent.Providers.ReasoningContent do
  @moduledoc """
  The one place that knows how an OpenAI-shaped payload spells "reasoning".

  ## The defect this exists to end

  `openai_compat.ex` matched exactly one spelling — `"reasoning_content"` — on
  exactly one path (streaming), and nothing anywhere in `lib/providers/`
  matched a bare `"reasoning"`. Those are two different vendors' words for the
  same field:

    * **`reasoning_content`** — DeepSeek's spelling, mirrored by the gateways
      that proxy DeepSeek-shaped backends verbatim (Together, Fireworks, some
      Zhipu/Moonshot deployments).
    * **`reasoning`** — OpenRouter's *unified* spelling. OpenRouter normalises
      every upstream reasoning field onto `choices[].delta.reasoning` (stream)
      and `choices[].message.reasoning` (sync), with the structured form under
      `reasoning_details`.

  OSA asks for reasoning on the OpenRouter route — `OpenAICompat.reasoning_decision/2`
  puts `reasoning_effort` on the body and the catalog says yes for
  `z-ai/glm-5.2` and `anthropic/claude-opus-5` — and then discarded every byte
  that came back. It is billed as output either way (see "Accounting" below),
  so the run paid for deliberation that reached neither the user, the TUI, nor
  the persisted transcript. Measured on this tree over `bench/swebenchpro/runs`:
  the ollama arm and the OpenRouter arm ran the *same twelve* SWE-bench-Pro
  instances with the same model family, and surfaced-text-per-billed-output-token
  came out 3.4x lower on OpenRouter. Zero `thinking_delta` events exist in any
  OpenRouter artefact on disk.

  ## Precedence, and why it is not a concatenation

  A gateway may send BOTH spellings in one delta carrying the same text —
  OpenRouter passes `reasoning_content` through from a DeepSeek upstream while
  also populating its own `reasoning`. Concatenating would print the model's
  deliberation twice. So this returns the FIRST non-empty of:

      "reasoning_content"  →  "reasoning"  →  "reasoning_details"

  `reasoning_content` leads so that the one route which already worked is
  byte-identical to what it was before this module existed.

  ## Accounting: nothing to add

  Reasoning tokens are already INSIDE the reported `completion_tokens` on every
  OpenAI-shaped API (OpenAI reports `completion_tokens_details.reasoning_tokens`
  as a *subset*; OpenRouter follows it). So this module is deliberately about
  TEXT only and touches no usage map. Adding a reasoning count to
  `output_tokens` would be the exact double-count `reconcile_prompt_slices/2`
  exists to prevent, and is the documented reason `openai_responses.ex`'s
  `:reasoning_tokens` is collected and never summed.

  The billed figures were therefore never wrong. What was wrong is that
  two-thirds of what they billed for was invisible.

  ## Not the assistant's answer

  Reasoning is surfaced as reasoning (`{:thinking_delta, text}`) and returned
  under a separate `:reasoning` result key. It is never concatenated into
  `:content`, and it is never written onto the assistant message — so it is not
  replayed to the provider on the next turn. That is the correct contract for
  the OpenAI-compatible transport: unlike Anthropic, which REQUIRES signed
  `thinking` blocks to be echoed back (`anthropic.ex:983-999`), chat/completions
  has no such requirement and OpenRouter documents `reasoning` as
  response-only. `ReactLoop` copies `:thinking_blocks` onto the assistant
  message and nothing else, and `OpenAICompat.format_messages/1` emits only
  `role`/`content`/`tool_calls`, so an unknown key could not reach the wire even
  by accident.
  """

  # Response-only keys, in precedence order. See "Precedence" above.
  @keys ["reasoning_content", "reasoning", "reasoning_details"]

  # Field names a structured reasoning block may carry its human-readable text
  # under. `reasoning.encrypted` blocks carry only an opaque `data` blob and are
  # deliberately absent: there is no text in them to surface, and rendering
  # base64 as the model's deliberation would be worse than rendering nothing.
  @text_keys ["text", "summary", "reasoning", "content", "thinking"]

  @doc """
  The reasoning text carried by an OpenAI-shaped `message` or streaming `delta`.

  Returns `""` when the payload carries none — which is the overwhelmingly
  common case (every non-reasoning model, every turn of a reasoning model that
  chose not to reason), so it must stay a cheap, total, non-raising function.

      iex> extract(%{"reasoning_content" => "step 1"})
      "step 1"

      iex> extract(%{"reasoning" => "step 1"})
      "step 1"

      iex> extract(%{"content" => "hello"})
      ""
  """
  @spec extract(term()) :: String.t()
  def extract(payload) when is_map(payload) do
    Enum.find_value(@keys, "", fn key ->
      case Map.get(payload, key) do
        nil -> nil
        value -> blank_to_nil(text_of(value))
      end
    end)
  end

  def extract(_), do: ""

  # A string field is the field.
  defp text_of(value) when is_binary(value), do: value

  # `reasoning_details` is a list of blocks; a gateway may also send a list
  # under `reasoning` itself. Join with no separator: these are consecutive
  # slices of one stream of thought, not independent items.
  defp text_of(value) when is_list(value) do
    value
    |> Enum.map(&text_of/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("")
  end

  # A single structured block: `%{"type" => "reasoning.text", "text" => "..."}`
  # and friends. First populated text field wins; an encrypted block yields "".
  defp text_of(value) when is_map(value) do
    Enum.find_value(@text_keys, "", fn key ->
      case Map.get(value, key) do
        v when is_binary(v) and v != "" -> v
        v when is_list(v) or is_map(v) -> blank_to_nil(text_of(v))
        _ -> nil
      end
    end)
  end

  # Numbers, booleans, nil: not text, and not worth an inspect/1 in the user's
  # thinking box.
  defp text_of(_), do: ""

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  @doc """
  Put `:reasoning` on a provider result map, but only when there is some.

  Absent rather than `""` on the empty case, so a consumer can pattern-match
  presence and no downstream `Map.get/2` has to distinguish "no reasoning" from
  "reasoning that happened to be blank".
  """
  @spec put_result(map(), String.t()) :: map()
  def put_result(result, text) when is_binary(text) and text != "",
    do: Map.put(result, :reasoning, text)

  def put_result(result, _), do: result
end
