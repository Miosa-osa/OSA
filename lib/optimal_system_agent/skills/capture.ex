defmodule OptimalSystemAgent.Skills.Capture do
  @moduledoc """
  Quality gate for the CAPTURE stage of the Skills subsystem (see
  `OptimalSystemAgent.Skills`).

  A learned library is only as good as what it refuses to store. Every path
  that writes a skill - the model-invoked `save_skill` tool and the automatic
  `Memory.Coordinator` consolidation - runs candidate attrs through `validate/1`
  first, so trivial one-offs never pollute retrieval and never crowd out the
  high-signal procedures that ranking is supposed to surface.

  A skill is HIGH-SIGNAL when it has all three of:

    1. a descriptive title,
    2. a real trigger - `when_to_use` (preferred) or `description` - that says
       WHEN to reuse it, so the ranker has something to match a future task
       against, and
    3. a substantive body: enough concrete steps/commands to be worth recalling,
       not a bare restatement of the title.

  This mirrors how Claude Code's `/skillify` treats capture as a deliberate,
  interview-quality act rather than an automatic dump of every action.
  """

  # Minimum lengths (characters, after trimming) and word counts.
  @min_title_len 3
  @min_trigger_len 12
  @min_body_len 40
  @min_body_words 6

  @doc """
  Validate candidate skill attrs (string- or atom-keyed). Returns `:ok` for a
  high-signal skill, `{:error, reason}` otherwise. Purely functional - no I/O.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(attrs) when is_map(attrs) do
    title = fetch(attrs, "title")
    body = fetch(attrs, "body")
    trigger = trigger_text(attrs)

    cond do
      String.length(title) < @min_title_len ->
        {:error, "skill needs a descriptive title (at least #{@min_title_len} characters)"}

      String.length(body) < @min_body_len ->
        {:error,
         "skill body is too thin to be reusable - capture the concrete steps/commands " <>
           "(at least #{@min_body_len} characters), not a one-off note"}

      word_count(body) < @min_body_words ->
        {:error,
         "skill body needs enough substance to be worth recalling " <>
           "(at least #{@min_body_words} words of actual procedure)"}

      String.length(trigger) < @min_trigger_len ->
        {:error,
         "skill needs a real when_to_use trigger describing WHEN to reuse it " <>
           "(at least #{@min_trigger_len} characters) so it can be matched to future tasks"}

      restatement?(title, body) ->
        {:error,
         "skill body just restates the title - record the actual procedure, " <>
           "not a paraphrase of the name"}

      true ->
        :ok
    end
  end

  def validate(_), do: {:error, "skill attrs must be a map"}

  @doc "Convenience boolean form of `validate/1`."
  @spec high_signal?(map()) :: boolean()
  def high_signal?(attrs), do: validate(attrs) == :ok

  # ── Private ────────────────────────────────────────────────────────────

  # A trigger can come from when_to_use OR description; prefer the longer, since
  # either gives the ranker something to match against.
  defp trigger_text(attrs) do
    when_to = fetch(attrs, "when_to_use")
    desc = fetch(attrs, "description")
    if String.length(when_to) >= String.length(desc), do: when_to, else: desc
  end

  defp restatement?(title, body) do
    normalize(title) == normalize(body)
  end

  defp normalize(s), do: s |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, " ") |> String.trim()

  defp word_count(s), do: s |> String.split(~r/\s+/, trim: true) |> length()

  # Fetch a key that may be a string or atom, coerced to a trimmed string.
  defp fetch(attrs, key) do
    (Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) || "")
    |> to_string()
    |> String.trim()
  end
end
