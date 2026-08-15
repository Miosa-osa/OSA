defmodule OptimalSystemAgent.Providers.StopReason do
  @moduledoc """
  Why a generation stopped — normalized across every provider OSA speaks to.

  ## Why this exists

  Every provider reports a terminal stop/finish reason, and every provider
  spells it differently. The agent loop had exactly one spelling hard-coded
  (`"max_tokens"`, Anthropic's) plus `"length"` on one clause, and three of the
  providers OSA actually ships never populated the field at all. The result was
  measured on `bench/terminalbench/runs/osa-tb20-full89-f6981b61`: on
  `regex-chess` the final generation stopped at exactly the 32,768-token output
  ceiling mid-sentence, and that fragment was delivered to the grader as the
  final answer. On `schemelike-metacircular-eval` the last three generations
  were all exactly 32,768 and the reasoning-only doom-loop guard reported them
  as a stalled model.

  A generation that stopped because it ran out of output budget is **not an
  answer**. Recognising that requires one place that knows every spelling.

  ## The wire values, per provider

  | provider | field | truncation value(s) | read by OSA before this module |
  |---|---|---|---|
  | Anthropic | `stop_reason` | `max_tokens` | yes |
  | OpenAI-compat (OpenAI, Groq, xAI, DeepSeek, OpenRouter, Together, …) | `choices[].finish_reason` | `length` | yes (streaming + sync) |
  | OpenAI Responses / Codex | `incomplete_details.reason` | `max_output_tokens` | captured, but the loop did not match the value |
  | Ollama (local + cloud) | `done_reason` | `length` | **no — never captured** |
  | Google Gemini | `candidates[].finishReason` | `MAX_TOKENS` | **no — never captured** |
  | Bedrock Converse | `stopReason` | `max_tokens` | **no — never captured** |
  | Cohere | `finish_reason` | `MAX_TOKENS` | **no — never captured** |
  | Replicate | — | (none published) | n/a |
  | claude_cli / copilot_cli | — | (subprocess, no stop reason on the wire) | n/a |

  The three "never captured" rows are the defect: OSA's default provider is
  Ollama, so on the configuration the benchmark ran under the truncation
  handling in `ReactLoop.handle_result/3` was **unreachable**.

  ## Contract

  `normalize/1` maps a raw wire value to a canonical atom. `truncated?/1`
  answers the only question the loop needs, and accepts either a raw string, a
  canonical atom, or a whole response map — so callers never have to remember
  which provider produced the map they are holding.

  Providers keep publishing their RAW string in `:stop_reason`; nothing is
  rewritten on the response. This module is the interpreter, not a rewriter,
  so an existing matcher on a literal `"max_tokens"` keeps working.
  """

  @typedoc """
  Canonical stop reason.

    * `:truncated`      — hit the output-token ceiling. NOT a complete answer.
    * `:stop`           — the model finished on its own.
    * `:tool_calls`     — the model finished by requesting tools.
    * `:content_filter` — blocked by a safety/guardrail filter.
    * `:error`          — the provider reported the generation failed.
    * `:unknown`        — no reason reported, or one we do not recognise.
  """
  @type t :: :truncated | :stop | :tool_calls | :content_filter | :error | :unknown

  # Every spelling of "you ran out of output tokens" across the supported
  # providers, lower-cased. Keep this list, not a substring/regex match: a
  # regex on "length" would also swallow `stop_sequence`-adjacent values from a
  # future provider, and a false positive here re-issues an expensive
  # generation for no reason.
  @truncated ~w(
    max_tokens
    length
    max_output_tokens
    max_completion_tokens
    model_length
    token_limit
    output_limit
  )

  @stop ~w(stop end_turn stop_sequence complete end_of_turn eos)
  @tool_calls ~w(tool_calls tool_use function_call tool_call)
  @content_filter ~w(content_filter content_filtered safety recitation guardrail_intervened blocked prohibited_content)
  @error ~w(error failed malformed_function_call unexpected_tool_call)

  @doc """
  Canonicalize a raw provider stop/finish reason.

  Case- and provider-insensitive. `nil`, `""` and anything unrecognised map to
  `:unknown` — deliberately NOT to `:stop`. "The provider did not tell us" and
  "the model finished" are different facts, and collapsing them is how a
  truncation gets delivered as an answer.

      iex> OptimalSystemAgent.Providers.StopReason.normalize("max_tokens")
      :truncated
      iex> OptimalSystemAgent.Providers.StopReason.normalize("MAX_TOKENS")
      :truncated
      iex> OptimalSystemAgent.Providers.StopReason.normalize("length")
      :truncated
      iex> OptimalSystemAgent.Providers.StopReason.normalize("end_turn")
      :stop
      iex> OptimalSystemAgent.Providers.StopReason.normalize(nil)
      :unknown
  """
  @spec normalize(term()) :: t()
  def normalize(reason) when is_binary(reason) do
    case reason |> String.trim() |> String.downcase() do
      "" -> :unknown
      r when r in @truncated -> :truncated
      r when r in @stop -> :stop
      r when r in @tool_calls -> :tool_calls
      r when r in @content_filter -> :content_filter
      r when r in @error -> :error
      _ -> :unknown
    end
  end

  def normalize(reason) when is_atom(reason) and not is_nil(reason) do
    if reason in [:truncated, :stop, :tool_calls, :content_filter, :error, :unknown] do
      reason
    else
      reason |> Atom.to_string() |> normalize()
    end
  end

  def normalize(_), do: :unknown

  @doc """
  True when this generation was cut off by the output-token ceiling.

  Accepts a raw string, a canonical atom, or a provider response map (with
  either a `:stop_reason` or `"stop_reason"` key). A map with no stop reason at
  all answers `false` — the honest answer for a provider that does not report
  one, and the reason `normalize/1` keeps `:unknown` separate from `:stop`.

      iex> alias OptimalSystemAgent.Providers.StopReason
      iex> StopReason.truncated?(%{content: "…", stop_reason: "length"})
      true
      iex> StopReason.truncated?(%{content: "done", stop_reason: "stop"})
      false
      iex> StopReason.truncated?(%{content: "done"})
      false
  """
  @spec truncated?(term()) :: boolean()
  def truncated?(%{stop_reason: reason}), do: normalize(reason) == :truncated
  def truncated?(%{"stop_reason" => reason}), do: normalize(reason) == :truncated
  def truncated?(map) when is_map(map), do: false
  def truncated?(reason), do: normalize(reason) == :truncated

  @doc """
  The raw stop reason carried by a response map, or `nil`.

  Kept next to `truncated?/1` so telemetry can report the provider's own word
  rather than OSA's canonical bucket — when a truncation is reported the log
  should name what actually came back on the wire.
  """
  @spec raw(term()) :: String.t() | nil
  def raw(%{stop_reason: r}) when is_binary(r), do: r
  def raw(%{"stop_reason" => r}) when is_binary(r), do: r
  def raw(r) when is_binary(r), do: r
  def raw(_), do: nil
end
