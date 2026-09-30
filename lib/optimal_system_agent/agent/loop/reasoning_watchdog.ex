defmodule OptimalSystemAgent.Agent.Loop.ReasoningWatchdog do
  @moduledoc """
  Live, in-stream detector for a degenerate (looping) generation.

  ## Why this exists

  A generation can go wrong WHILE it is streaming, not just after it ends.
  Measured live on `deepseek-v4.1-flash:cloud` (Ollama Cloud, overdrive,
  ~136K context): the model spent 74 seconds looping short filler on its
  reasoning channel ("OK." repeated over a dozen times, "Let me write",
  never converging on either a tool call or an answer) and nothing in OSA
  noticed - the user had to press Esc. Two existing guards do not cover this:

    * `DoomLoop.ReasoningOnly` only sees a generation AFTER it ends with zero
      tool calls - it cannot see the loop WHILE tokens are still streaming.
    * `Regulation.Pain`'s `reasoning_overflow_ms` signal is the same shape:
      computed post-hoc from `state.last_generation_ms`, after the call
      already finished.

  This module is the missing piece: a cheap, incremental state machine fed
  every streamed delta (reasoning AND plain text, on every provider path,
  since `LLMClient.llm_chat_stream/3` is the one callback every provider
  routes through) that can trip WHILE the stream is still open.

  ## Detection rules (all four from the incident review)

    * `:repeated_phrase` - a short line/phrase repeated many times in the
      recent window (the actual incident shape: `"OK." x14`).
    * `:ngram_repetition` - a high fraction of repeated n-grams (5-word
      spans by default) over the recent window - catches near-repeats that
      are not byte-identical short lines.
    * `:lexical_collapse` - the unique-token ratio over the last K tokens
      has collapsed (the model is cycling a small vocabulary).
    * `:stalled` - the channel has run past a configured time OR character
      bound with NEITHER a tool call NOR any answer text yet - a backstop
      for a stall that never repeats content verbatim but also never
      converges.

  Every threshold is configurable (`config :optimal_system_agent,
  :reasoning_watchdog, [...]`) with conservative defaults chosen so a long,
  varied, PRODUCTIVE reasoning stream never trips - see
  `reasoning_watchdog_test.exs` for the realistic-long-reasoning fixture this
  is measured against.

  ## Cost

  Each `observe/3` call only re-runs the checks once at least
  `check_every_chars/0` new characters have accumulated since the last check,
  and every check runs over a BOUNDED trailing window
  (`window_chars/0`, default 2,000 chars) - never the whole accumulated
  transcript - so a long stream costs the same per-check regardless of how
  long it has already run.
  """

  @type channel :: :reasoning | :text

  @type rule :: :repeated_phrase | :ngram_repetition | :lexical_collapse | :stalled

  @type trip :: %{rule: rule(), channel: channel(), cause: String.t(), sample: String.t()}

  @type t :: %__MODULE__{
          started_ms: integer(),
          reasoning_buf: String.t(),
          text_buf: String.t(),
          reasoning_chars_total: non_neg_integer(),
          tool_call?: boolean(),
          answer?: boolean(),
          pending_chars: non_neg_integer()
        }

  defstruct started_ms: 0,
            reasoning_buf: "",
            text_buf: "",
            reasoning_chars_total: 0,
            tool_call?: false,
            answer?: false,
            pending_chars: 0

  @doc "A fresh watchdog for one generation, clocked from now."
  @spec new() :: t()
  def new, do: %__MODULE__{started_ms: System.monotonic_time(:millisecond)}

  @doc "Record that a tool call started streaming - clears the `:stalled` backstop."
  @spec note_tool_call(t()) :: t()
  def note_tool_call(%__MODULE__{} = w), do: %{w | tool_call?: true}

  @doc """
  Fold one streamed delta into the watchdog and check for degeneration.

  Returns `{:ok, watchdog}` when nothing tripped, or `{:trip, info, watchdog}`
  the first time a rule fires. The caller is expected to abort the stream on
  a trip and discard the watchdog - `observe/3` does not suppress repeat
  trips on its own.
  """
  @spec observe(t(), channel(), String.t()) :: {:ok, t()} | {:trip, trip(), t()}
  def observe(%__MODULE__{} = w, channel, delta) when channel in [:reasoning, :text] do
    if is_binary(delta) and delta != "" do
      w = fold(w, channel, delta)

      if w.pending_chars >= check_every_chars() do
        w = %{w | pending_chars: 0}

        case check(w) do
          :ok -> {:ok, w}
          {:trip, info} -> {:trip, info, w}
        end
      else
        {:ok, w}
      end
    else
      {:ok, w}
    end
  end

  def observe(%__MODULE__{} = w, _channel, _delta), do: {:ok, w}

  defp fold(w, :reasoning, delta) do
    %{
      w
      | reasoning_buf: append_bounded(w.reasoning_buf, delta),
        reasoning_chars_total: w.reasoning_chars_total + byte_size(delta),
        pending_chars: w.pending_chars + byte_size(delta)
    }
  end

  defp fold(w, :text, delta) do
    %{
      w
      | text_buf: append_bounded(w.text_buf, delta),
        answer?: true,
        pending_chars: w.pending_chars + byte_size(delta)
    }
  end

  # Keeps only the trailing `window_chars/0` CHARACTERS (grapheme-aware via
  # `String.slice/3`, so a multi-byte codepoint straddling the cut point can
  # never split and crash this - frequent, on every delta - caller).
  defp append_bounded(buf, delta) do
    combined = buf <> delta
    max = window_chars()

    if String.length(combined) > max do
      String.slice(combined, -max, max)
    else
      combined
    end
  end

  # ── Checks ────────────────────────────────────────────────────────────────

  defp check(w) do
    with :ok <- check_channel(w, :reasoning, w.reasoning_buf),
         :ok <- check_channel(w, :text, w.text_buf) do
      check_stalled(w)
    end
  end

  defp check_channel(w, channel, buf) when byte_size(buf) > 0 do
    with :ok <- check_repeated_phrase(w, channel, buf),
         :ok <- check_ngram_repetition(w, channel, buf) do
      check_lexical_collapse(w, channel, buf)
    end
  end

  defp check_channel(_w, _channel, _buf), do: :ok

  # Rule (a): a short line/phrase repeated many times in the window.
  defp check_repeated_phrase(_w, channel, buf) do
    phrases =
      buf
      |> String.split(~r/[\n]|(?<=[.!?])\s+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.length(&1) > short_phrase_max_chars()))

    case phrases do
      [] ->
        :ok

      _ ->
        {phrase, count} =
          phrases
          |> Enum.frequencies()
          |> Enum.max_by(fn {_p, c} -> c end, fn -> {nil, 0} end)

        if phrase != nil and count >= repeated_phrase_threshold() do
          {:trip,
           %{
             rule: :repeated_phrase,
             channel: channel,
             cause: "reasoning looped (\"#{phrase}\" x#{count})",
             sample: phrase
           }}
        else
          :ok
        end
    end
  end

  # Rule (b): high n-gram repetition ratio over the window.
  defp check_ngram_repetition(_w, channel, buf) do
    words = String.split(buf)
    n = ngram_n()

    if length(words) >= n + ngram_min_total() do
      ngrams = words |> Enum.chunk_every(n, 1, :discard) |> Enum.map(&Enum.join(&1, " "))
      total = length(ngrams)
      unique = ngrams |> Enum.uniq() |> length()
      ratio = if total > 0, do: 1 - unique / total, else: 0.0

      if ratio >= ngram_repetition_ratio() do
        sample = ngrams |> Enum.frequencies() |> Enum.max_by(fn {_g, c} -> c end) |> elem(0)

        {:trip,
         %{
           rule: :ngram_repetition,
           channel: channel,
           cause: "reasoning repeating the same phrases (#{round(ratio * 100)}% repeated)",
           sample: sample
         }}
      else
        :ok
      end
    else
      :ok
    end
  end

  # Rule (c): collapsing lexical diversity over the last K tokens.
  defp check_lexical_collapse(_w, channel, buf) do
    words = String.split(buf)
    k = lexical_window_tokens()

    if length(words) >= k do
      tail = Enum.take(words, -k)
      unique = tail |> Enum.uniq() |> length()
      ratio = unique / k

      if ratio <= lexical_diversity_floor() do
        {:trip,
         %{
           rule: :lexical_collapse,
           channel: channel,
           cause: "reasoning lost variety (repeating a small set of words)",
           sample: tail |> Enum.uniq() |> Enum.take(5) |> Enum.join(" ")
         }}
      else
        :ok
      end
    else
      :ok
    end
  end

  # Rule (d): time/char backstop - reasoning that never converges on a tool
  # call or an answer. Deliberately conservative (see moduledoc) since this
  # rule alone has no content signal.
  defp check_stalled(w) do
    if w.tool_call? or w.answer? do
      :ok
    else
      elapsed_ms = System.monotonic_time(:millisecond) - w.started_ms

      cond do
        elapsed_ms >= max_reasoning_ms() ->
          {:trip,
           %{
             rule: :stalled,
             channel: :reasoning,
             cause: "reasoning ran #{fmt_duration(elapsed_ms)} with no tool call or answer",
             sample: ""
           }}

        w.reasoning_chars_total >= max_reasoning_chars() ->
          {:trip,
           %{
             rule: :stalled,
             channel: :reasoning,
             cause:
               "reasoning produced #{w.reasoning_chars_total} characters with no tool call or answer",
             sample: ""
           }}

        true ->
          :ok
      end
    end
  end

  defp fmt_duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"

  defp fmt_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    if seconds == 0, do: "#{minutes}m", else: "#{minutes}m#{seconds}s"
  end

  # ── Config ──────────────────────────────────────────────────────────────

  @default_window_chars 2_000
  @default_check_every_chars 40
  @default_short_phrase_max_chars 40
  @default_repeated_phrase_threshold 8
  @default_ngram_n 5
  @default_ngram_min_total 30
  @default_ngram_repetition_ratio 0.6
  @default_lexical_window_tokens 60
  @default_lexical_diversity_floor 0.2
  @default_max_reasoning_ms 150_000
  @default_max_reasoning_chars 60_000

  defp config, do: Application.get_env(:optimal_system_agent, :reasoning_watchdog, [])

  @doc "Whether the watchdog is active at all - the master off switch."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true)

  @doc false
  def window_chars, do: pos_int(:window_chars, @default_window_chars)
  @doc false
  def check_every_chars, do: pos_int(:check_every_chars, @default_check_every_chars)
  @doc false
  def short_phrase_max_chars,
    do: pos_int(:short_phrase_max_chars, @default_short_phrase_max_chars)

  @doc false
  def repeated_phrase_threshold,
    do: pos_int(:repeated_phrase_threshold, @default_repeated_phrase_threshold)

  @doc false
  def ngram_n, do: pos_int(:ngram_n, @default_ngram_n)
  @doc false
  def ngram_min_total, do: pos_int(:ngram_min_total, @default_ngram_min_total)
  @doc false
  def lexical_window_tokens, do: pos_int(:lexical_window_tokens, @default_lexical_window_tokens)
  @doc false
  def max_reasoning_ms, do: pos_int(:max_reasoning_ms, @default_max_reasoning_ms)
  @doc false
  def max_reasoning_chars, do: pos_int(:max_reasoning_chars, @default_max_reasoning_chars)

  @doc false
  def ngram_repetition_ratio do
    case Keyword.get(config(), :ngram_repetition_ratio, @default_ngram_repetition_ratio) do
      f when is_number(f) and f > 0.0 and f <= 1.0 -> f
      _ -> @default_ngram_repetition_ratio
    end
  end

  @doc false
  def lexical_diversity_floor do
    case Keyword.get(config(), :lexical_diversity_floor, @default_lexical_diversity_floor) do
      f when is_number(f) and f > 0.0 and f <= 1.0 -> f
      _ -> @default_lexical_diversity_floor
    end
  end

  defp pos_int(key, default) do
    case Keyword.get(config(), key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end
end
