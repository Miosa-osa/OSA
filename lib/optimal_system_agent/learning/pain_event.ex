defmodule OptimalSystemAgent.Learning.PainEvent do
  @moduledoc """
  A single unit of "algedonic" friction observed during a turn — the raw
  material `OptimalSystemAgent.Learning.DoubleLoop` turns into durable
  lessons at session end and at compaction.

  This struct (and `new/4`) is the NARROW boundary of OSA's turn-level pain
  channel. A dedicated, richer per-turn pain emitter is being built
  elsewhere; until it lands, everything that observes friction in this
  codebase — `OptimalSystemAgent.Agent.Loop.ToolRetry`, the `pain_observer_*`
  hooks in `OptimalSystemAgent.Agent.Hooks.Handlers` — constructs one of
  these and hands it to `OptimalSystemAgent.Learning.PainSink.record/4`. When
  the richer emitter lands, it only needs to agree on this same shape.

  ## Sanitisation

  `new/4` is the ONLY constructor and it always sanitises `detail` via
  `sanitize/1`: secret-shaped substrings are redacted, anything that looks
  like a dumped file/diff is collapsed to a short synopsis, and the result is
  hard-capped in length. Nothing downstream — the ETS buffer, the mirrored
  Bus alert, an eventual lesson — ever sees the raw value. This is the
  concrete answer to "never store secrets or file contents verbatim": enforce
  it once, at the boundary, rather than trusting every call site.
  """

  @kinds ~w(repeated_probe reverification_loop command_fix wrong_checkout slow_search user_correction other)a

  @type kind ::
          :repeated_probe
          | :reverification_loop
          | :command_fix
          | :wrong_checkout
          | :slow_search
          | :user_correction
          | :other

  @type t :: %__MODULE__{
          kind: kind(),
          session_id: String.t() | nil,
          detail: String.t(),
          metadata: map(),
          at: DateTime.t()
        }

  defstruct [:kind, :session_id, :detail, :at, metadata: %{}]

  @doc "The fixed pain-kind vocabulary. Anything else normalizes to `:other`."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Build a sanitised pain event.

  An unrecognised `kind` normalizes to `:other` rather than raising —
  misclassifying a pain signal must never crash the real turn that is
  reporting it.
  """
  @spec new(kind() | atom(), String.t() | nil, term(), map()) :: t()
  def new(kind, session_id, detail, metadata \\ %{}) do
    %__MODULE__{
      kind: normalize_kind(kind),
      session_id: session_id,
      detail: sanitize(detail),
      metadata: metadata,
      at: DateTime.utc_now()
    }
  end

  defp normalize_kind(kind) when kind in @kinds, do: kind
  defp normalize_kind(_), do: :other

  @max_detail_length 200
  # Below this, a multi-line detail is treated as legitimate short structure
  # (e.g. a two-line error) rather than a dumped file — only genuinely long
  # multi-line blobs, or anything carrying an explicit diff marker, collapse.
  @dump_line_threshold 6

  @secret_patterns [
    ~r/bearer\s+[A-Za-z0-9\-\._~\+\/]+=*/i,
    ~r/\bsk-[A-Za-z0-9]{10,}\b/,
    ~r/\bghp_[A-Za-z0-9]{10,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/(api[_-]?key|secret|token|password)\s*[=:]\s*\S+/i,
    ~r/\b[A-Za-z0-9+\/]{40,}={0,2}\b/
  ]

  @doc """
  Redact secret-shaped substrings, collapse anything that looks like a
  dumped file/diff into a short synopsis, collapse internal whitespace, and
  hard-cap the result at #{@max_detail_length} characters.
  """
  @spec sanitize(term()) :: String.t()
  def sanitize(text) when is_binary(text) do
    text
    |> collapse_file_dump()
    |> redact_secrets()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @max_detail_length)
  end

  def sanitize(other), do: other |> inspect() |> sanitize()

  defp collapse_file_dump(text) do
    line_count = text |> String.split("\n") |> length()

    looks_like_dump? =
      line_count > @dump_line_threshold or
        String.contains?(text, "diff --git") or
        String.contains?(text, "+++ b/") or
        String.contains?(text, "--- a/")

    if looks_like_dump? do
      "[omitted: #{line_count}-line file/diff content]"
    else
      text
    end
  end

  defp redact_secrets(text) do
    Enum.reduce(@secret_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, "[redacted]")
    end)
  end
end
