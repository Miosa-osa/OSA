defmodule OptimalSystemAgent.Agent.Loop.TerminalSource do
  @moduledoc """
  Who wrote the thing the user is about to read as the answer.

  ## The defect this exists to close

  `ReactLoop.run/1` returns `{String.t(), map()}`. One channel, one untyped
  string. The model's answer and a guard's internal advice are the same type, so
  `Loop.run_and_reply/1` — which cannot tell them apart — appended both to the
  transcript as `role: "assistant"` and broadcast both as
  `response_type: "agent"`.

  Measured consequence, on the `schemelike` benchmark instance: the doom-loop
  guard's own text — *"3 consecutive generations produced no tool calls"* —
  was delivered to the user as the model's final answer. That text is a note
  from the harness to itself. It is not an answer, it was never addressed to
  the user, and presenting it as the assistant's reply is a lie about who is
  speaking.

  (The compounding half of that incident — that the three generations were
  provider TRUNCATIONS, so the guard was reporting a cut-off model as a stalled
  one — is fixed separately in `DoomLoop.ReasoningOnly`. This module addresses
  what remains: even a CORRECT guard firing must not be able to impersonate the
  model.)

  ## What this does

  Every terminal string now carries provenance in the loop state, and the
  provenance is stamped onto the wire beside it. Four sources:

    * `:model`   — the model actually answered. The only source that renders as
      an assistant message.
    * `:guard`   — a doom-loop / stall / reasoning-only guard stopped the turn.
      Its text is advice about the loop, not about the task.
    * `:control` — a non-guard control-flow stop: budget cap, turn cap, max
      iterations, pause, hook block, guardrail refusal.
    * `:error`   — the turn died: provider outage, fatal tool error, context
      overflow, crash, exit.

  ## Why the default is `:model` and why that is safe

  Marking is opt-in at the halt sites rather than opt-out at the answer site,
  which looks like the weaker choice. It is not, because of `reset/1`: the mark
  is cleared at the start of every turn, so a stale `:guard` can never leak
  forward into a turn that ended normally. The failure mode of a forgotten mark
  is "a new control-flow path renders as an answer" — the status quo ante, no
  worse — rather than "the model's real answer is hidden behind a system
  chrome", which would be a regression affecting every healthy turn.

  ## Deliberately NOT done: rewriting the text

  It would be easy to prefix guard text with `[System: …]` and be done. That was
  rejected. Text prefixes are what the codebase already does for
  `interrupt_markers/0`, and the result is a contract enforced by string
  comparison across a language boundary — `Loop` re-matches the marker to decide
  a message's ROLE (`loop.ex`), and the Rust TUI re-matches it again to decide
  rendering. String matching is how you get a marker that silently stops working
  when someone edits the sentence.

  Provenance belongs in a field. The text stays exactly as the guard wrote it,
  which also keeps the existing guard tests meaningful — they assert on the
  message, and the message has not changed.
  """

  @typedoc "Who authored the terminal text."
  @type t :: :model | :guard | :control | :error

  @key :terminal_source

  @sources [:model, :guard, :control, :error]

  @doc """
  Record who authored the terminal text for this turn.

  Ignores unknown sources rather than raising: an observability mechanism must
  never be the reason a turn fails to deliver.
  """
  @spec mark(map(), t()) :: map()
  def mark(state, source) when is_map(state) and source in @sources,
    do: Map.put(state, @key, source)

  def mark(state, _source), do: state

  @doc """
  Mark and return in the shape the halt sites already use.

  Guard and control-flow sites return `{text, state}` tuples. This lets them keep
  that shape while recording provenance in one call, so the mark cannot be
  forgotten separately from the return:

      {:halt, msg, state} -> TerminalSource.halt(msg, state, :guard)
  """
  @spec halt(String.t(), map(), t()) :: {String.t(), map()}
  def halt(text, state, source), do: {text, mark(state, source)}

  @doc """
  Who authored the terminal text. Defaults to `:model`.
  """
  @spec of(map()) :: t()
  def of(state) when is_map(state) do
    case Map.get(state, @key) do
      s when s in @sources -> s
      _ -> :model
    end
  end

  def of(_), do: :model

  @doc """
  `true` when the terminal text is the model's own answer.
  """
  @spec model?(map()) :: boolean()
  def model?(state), do: of(state) == :model

  @doc """
  Clear the mark.

  Called at turn entry. This is what makes an opt-in mark safe: without it, one
  guard halt would make every subsequent turn in the session render as a system
  message.
  """
  @spec reset(map()) :: map()
  def reset(state) when is_map(state), do: Map.delete(state, @key)
  def reset(state), do: state

  @doc """
  The `response_type` value to put on the wire.

  `"agent"` is preserved verbatim for model answers so every existing consumer —
  the TUI, the CLI, SSE clients, the benchmark harness — is bit-for-bit
  unaffected on the healthy path. Non-model sources get their own value, which
  older clients will simply not recognise and render as they do today. Additive,
  not breaking.
  """
  @spec response_type(map() | t()) :: String.t()
  def response_type(source) when source in @sources do
    case source do
      :model -> "agent"
      :guard -> "system"
      :control -> "system"
      :error -> "system"
    end
  end

  def response_type(state) when is_map(state), do: response_type(of(state))

  @doc """
  Short human label for the class of stop, for clients that want to show why the
  turn ended without parsing the text.

  `nil` for `:model` — a normal answer needs no explanation.
  """
  @spec label(map() | t()) :: String.t() | nil
  def label(:model), do: nil
  def label(:guard), do: "loop guard"
  def label(:control), do: "stopped"
  def label(:error), do: "error"
  def label(state) when is_map(state), do: label(of(state))
end
