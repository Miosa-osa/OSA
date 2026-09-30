defmodule OptimalSystemAgent.Providers.ToolBoundarySpace do
  @moduledoc """
  Restores the space Ollama drops in front of the last content chunk before a
  tool call.

  ## The upstream defect

  When a model writes a line of narration and then calls a tool, Ollama's
  server-side tool-call parsing hands back the content that arrived in the SAME
  step as the tool-call marker with its surrounding whitespace trimmed. The
  trailing trim is intended (whitespace before the marker); the LEADING trim is
  not, and it deletes the word boundary in front of that last piece of prose:

      {"message":{"content":" can see the listing"}}
      {"message":{"content":"instead."}}          <- was " instead."
      {"message":{"tool_calls":[...]}}

  Measured against the operator's local daemon (`deepseek-v4.1-flash:cloud`,
  both `/api/chat` and `/v1/chat/completions`, `think` on and off) with no OSA
  code in the path: roughly one tool-calling message in five loses the space.
  The raw NDJSON lines are what OSA streams to the screen AND what it persists,
  so the glued words ("fileinstead.", "thesweep.", "bothinstant.") showed up
  live, in scrollback, in the saved transcript, and in the history the model
  reads back.

  ## Why the repair is a judgement, not a rule

  The dropped byte is gone; nothing on the wire says which chunk lost it.
  "Last content chunk before a tool call, letter against letter" is necessary
  but not sufficient: streamed chunks also split INSIDE words ("work" + "tree",
  "resp" + "awned"; about 9% of chunk boundaries in measured narration), and
  inserting a space there would trade one broken word for another.

  So a held chunk is only given its space back when BOTH sides of the seam are
  ordinary words and the two together are not one:

    * the head of the chunk (its leading letters) is a common English word;
    * the tail of what came before is at least two letters, or is `a` / `I`
      (a lone capital like "X" + "PC" is an acronym being spelled out);
    * the joined form is not itself a common word ("any" + "thing",
      "some" + "one").

  The word list is deliberately small and deliberately common: narration ends
  on everyday words ("instead", "anything", "up", "default", "them"), and a
  word missing from the list only means the old glued output, never a new
  split. Technical compounds whose halves are both common ("work" + "tree") are
  the residual false-positive class; "tree"/"trees" are kept out of the list
  for exactly that reason.

  ## Streaming shape

  Only a chunk that COULD need repair (it starts with a letter or digit and the
  text before it ends with one) is held, and only until the next stream event:
  more content or reasoning releases it untouched, a tool call releases it with
  the verdict above. Every other chunk passes straight through, so a stream
  that never touches a tool boundary is byte-for-byte unchanged.
  """

  # `tail` is the end of the text already released — just enough to judge the
  # seam (the last word), never the whole message.
  defstruct held: nil, tail: ""

  @type t :: %__MODULE__{held: String.t() | nil, tail: String.t()}

  @tail_keep 64

  @doc "A fresh holder."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Accept a chunk of VISIBLE text (reasoning already split off).

  Returns `{pieces, state}`: the pieces to emit now, in order — empty when this
  chunk is the one being held.
  """
  @spec content(t(), String.t()) :: {[String.t()], t()}
  def content(%__MODULE__{} = st, ""), do: {[], st}

  def content(%__MODULE__{held: held, tail: tail}, chunk) when is_binary(chunk) do
    released = if held, do: [held], else: []
    before = if held, do: tail <> held, else: tail

    if candidate?(before, chunk) do
      {released, %__MODULE__{held: chunk, tail: keep_tail(before)}}
    else
      {released ++ [chunk], %__MODULE__{tail: keep_tail(before <> chunk)}}
    end
  end

  @doc """
  A tool call arrived: release the held chunk, with its space restored when the
  seam reads as two separate words.
  """
  @spec tool_call(t()) :: {[String.t()], t()}
  def tool_call(%__MODULE__{held: nil} = st), do: {[], st}

  def tool_call(%__MODULE__{held: held, tail: tail}) do
    piece = if restore_space?(tail, held), do: " " <> held, else: held
    {[piece], %__MODULE__{tail: keep_tail(tail <> piece)}}
  end

  @doc "Release the held chunk unchanged (more prose, reasoning, or stream end)."
  @spec flush(t()) :: {[String.t()], t()}
  def flush(%__MODULE__{held: nil} = st), do: {[], st}

  def flush(%__MODULE__{held: held, tail: tail}),
    do: {[held], %__MODULE__{tail: keep_tail(tail <> held)}}

  defp keep_tail(s) do
    if String.length(s) > @tail_keep, do: String.slice(s, -@tail_keep, @tail_keep), else: s
  end

  @doc false
  @spec candidate?(String.t(), String.t()) :: boolean()
  def candidate?(before, chunk) do
    ends_alnum?(before) and starts_alnum?(chunk)
  end

  @doc """
  Would `before <> " " <> chunk` be the intended text rather than
  `before <> chunk`? See the moduledoc for the rule.
  """
  @spec restore_space?(String.t(), String.t()) :: boolean()
  def restore_space?(before, chunk) do
    with true <- candidate?(before, chunk),
         tail when tail != "" <- trailing_letters(before),
         head when head != "" <- leading_letters(chunk) do
      tail = String.downcase(tail)
      head = String.downcase(head)

      (tail in ["a", "i"] or String.length(tail) >= 2) and word?(head) and
        not word?(tail <> head)
    else
      _ -> false
    end
  end

  defp ends_alnum?(""), do: false
  defp ends_alnum?(s), do: String.match?(s, ~r/[\p{L}\p{N}]\z/u)

  defp starts_alnum?(s), do: String.match?(s, ~r/\A[\p{L}\p{N}]/u)

  defp trailing_letters(s) do
    case Regex.run(~r/[\p{L}']+\z/u, s) do
      [m] -> String.trim_leading(m, "'")
      _ -> ""
    end
  end

  defp leading_letters(s) do
    case Regex.run(~r/\A\p{L}+/u, s) do
      [m] -> m
      _ -> ""
    end
  end

  # ── The vocabulary ──────────────────────────────────────────────────────

  @words ~w(
    a about above across act action actions actual actually add added adds after again against
    agent ahead all almost alone along already also always an and another answer any anything
    anyway app apply are area around as ask at audit available away back bad base basic be
    because been before begin behind being below best better between big bit both bottom box
    branch break bring broken bug bugs build built but button by call called calls can cannot
    case cases catch cause change changed changes check checked checks clean clear close closed
    code command commands commit complete config confirm context copy correct could count
    current cut data date day dead default defaults delete did diff different directly do
    does doing done down drop dropped dropping during each early easy edit either else empty
    end enough entry error errors even event events every everything exact exactly exist
    exists expected explain fail failed failing fails false far fast few field file files
    final finally find finish first fix fixed fixes flag folder for found free fresh from full
    fully get gets give go goes going gone good got great group had half hand handle happen
    happened happens hard has have having he head help her here high him his hold hook how
    however idea if in inside instant instead into inventory is issue issues it item items
    its itself job just keep key kind know known last late later least left less let level
    lib like line lines list listing little live load loaded local lock log logs long look
    looking looks loop lost low main make makes many match may maybe me mean means message
    method might missing mode more most move much must my name need needed needs never new
    next no node none nor not note nothing now number of off old on once one only open or
    order other our out output over own page part pass passed passes past path per piece
    place plan point port possible prompt proper properly pull push put quick quickly quite
    rather raw re reach read reading ready real really reason rebuild rebuilt record repo
    report request respond result results return right root rule run running runs safe same save
    saw say says see seen send sent server set sets setting settings setup she should show
    side simple since single size skip small so some something soon source space start
    started starts state status step still stop stopped sure sweep switch system take task
    test tested tests text than that the their them then there these they thing things this
    those through time to today together too tool tools top total touch true try trying turn
    two type under unit until up update updated us use used using valid value values version
    very view wait want was way we well went were what when where whether which while who
    whole why will with within without work working works would write wrong yes yet you
    your

    also anyone anywhere backup become beyond checkout database download everyone
    everywhere filename himself herself input keyboard lookup myself nowhere onto
    outside overall runtime somebody someone sometimes somewhere themselves timeout
    understand upload username whatever whenever wherever workflow yourself
  )
  @word_set MapSet.new(@words)

  # Particles and short function words are real words, but they are also the
  # tails of countless compounds ("check" + "out" -> "checkouts"), so they are
  # never accepted as the STEM of an inflected form.
  @no_inflect ~w(a an as at be by do go he if in is it me my no of on or so to up us we
                 out off all any per own)

  defp word?(w) do
    MapSet.member?(@word_set, w) or inflected?(w)
  end

  defp inflected?(w) do
    Enum.any?(stems(w), fn stem ->
      String.length(stem) >= 3 and stem not in @no_inflect and MapSet.member?(@word_set, stem)
    end)
  end

  defp stems(w) do
    for {suffix, restore} <- [
          {"ies", "y"},
          {"es", ""},
          {"s", ""},
          {"ed", ""},
          {"ed", "e"},
          {"ing", ""},
          {"ing", "e"},
          {"ly", ""},
          {"er", ""}
        ],
        String.ends_with?(w, suffix),
        base = String.slice(w, 0, String.length(w) - String.length(suffix)),
        stem <- [base <> restore | undouble(base)] do
      stem
    end
  end

  # "dropping" -> "dropp" -> "drop"
  defp undouble(base) do
    case String.graphemes(base) |> Enum.reverse() do
      [c, c | rest] -> [rest |> Enum.reverse() |> Enum.join() |> Kernel.<>(c)]
      _ -> []
    end
  end
end
