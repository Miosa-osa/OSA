defmodule OptimalSystemAgent.Tools.Ablation do
  @moduledoc """
  One switch per tool-output feature, so a feature's cost can be measured by
  removing it rather than argued about.

  ## Why this exists

  Every token-reduction change we have shipped was justified by a number that
  came from reading the code, not from removing the feature and looking at what
  broke. That produced two failures we can name: fixes whose gains overlapped
  and were therefore counted twice, and two "improvements" that turned out to
  be logging artifacts. Neither is a reasoning failure — they are both the
  absence of a control.

  An ablation is the control. Toggle exactly one feature, re-run a fixed set of
  hostile inputs, and report the token delta ALONGSIDE whether the facts a
  caller needs are still recoverable from the output. A token cut that loses a
  fact is not a saving, and no amount of code reading distinguishes the two.

  ## Defaults are production

  Every flag defaults to ON — that is, to current shipped behaviour. Reading a
  flag that was never set returns `true`, so this module is invisible unless a
  harness deliberately turns something off. There is no config file, no env var
  and no application setting that can flip these; the only writer is
  `with_flags/2`, which sets them in the CALLING PROCESS's dictionary and
  restores them afterwards.

  That is deliberate. A global switch on tool output is a foot-gun: a stray
  setting in a config file would silently degrade a live session's reads, and
  the resulting bug would look like a model failure rather than a config one.
  Process-scoped means an ablation run cannot escape the process running it,
  and a live agent — which never calls `with_flags/2` — cannot be affected by
  one at all.

  ## Flags

    * `:read_stamps` — the EOF / continuation stamps `file_read` appends so a
      caller can tell "the file ends here" from "the window ends here".
    * `:read_unchanged_suppression` — replacing a byte-identical re-read with a
      short notice instead of the file's contents.
    * `:read_range_subtraction` — sending only the part of a requested window
      the session does not already hold, with the omission named, instead of the
      whole window. Off restores "any window that is not byte-identical returns
      in full", which is what shipped before and which addressed 0.8% of the
      measured read payload.
    * `:read_line_clamp` — the per-line character cap that stops one minified
      line from being megabytes.
    * `:edit_diff_echo` — echoing a synthetic unified diff back for an edit
      whose match was EXACT (currently OFF in production; the flag exists to
      measure what turning it off bought).
    * `:edit_diff_anchor` — computing the fuzzy-match diff from the real before
      and after content instead of guessing the hunk's position by scanning for
      the first line that CONTAINS `old_string`'s first line. Off restores the
      guess, which is what shipped until now.
    * `:grep_coverage` — `file_grep` widening its search to ignored, hidden and
      dependency files when the ordinary search finds nothing, and naming its
      coverage limit when it truncates. Off restores a bare
      "No matches found." for both cases.

  `:edit_diff_echo` is the odd one out: it is the only flag whose ON state is
  NOT production, because the feature was already removed. Its default is
  therefore `false`, and the ablation runs it in reverse — enabling it to price
  a decision already taken. Stated here because a reader who assumes every
  default is `true` would misread the table.
  """

  @pd_key :osa_ablation_flags

  # Every flag and the value that corresponds to shipped behaviour.
  @defaults %{
    read_stamps: true,
    read_unchanged_suppression: true,
    read_range_subtraction: true,
    read_line_clamp: true,
    edit_diff_echo: false,
    edit_diff_anchor: true,
    grep_coverage: true
  }

  @doc "Every known flag with its production value."
  @spec defaults() :: %{atom() => boolean()}
  def defaults, do: @defaults

  @doc "Every known flag name."
  @spec flags() :: [atom()]
  def flags, do: @defaults |> Map.keys() |> Enum.sort()

  @doc """
  Is `flag` active in this process?

  Answers the production default for any flag never explicitly set, which is
  every call outside a harness. Unknown flags answer `true` rather than raising:
  this sits on the tool hot path, and a typo in a flag name must not be able to
  take a live read down.
  """
  @spec on?(atom()) :: boolean()
  def on?(flag) do
    case Process.get(@pd_key) do
      %{^flag => value} when is_boolean(value) -> value
      _ -> Map.get(@defaults, flag, true)
    end
  end

  @doc """
  Run `fun` with `overrides` applied, then restore whatever was set before.

  Restoration runs in an `after`, so a raising body still leaves the process
  clean — otherwise one failing ablation case would silently contaminate every
  case after it, which is the exact class of bug this harness exists to catch.
  """
  @spec with_flags(map() | keyword(), (-> result)) :: result when result: term()
  def with_flags(overrides, fun) when is_list(overrides),
    do: with_flags(Map.new(overrides), fun)

  def with_flags(overrides, fun) when is_map(overrides) and is_function(fun, 0) do
    prior = Process.get(@pd_key)
    Process.put(@pd_key, Map.merge(prior || %{}, overrides))

    try do
      fun.()
    after
      if prior, do: Process.put(@pd_key, prior), else: Process.delete(@pd_key)
    end
  end

  @doc """
  Every flag at its production value except `flag`, which is inverted.

  This is the unit of the experiment: one feature moved, everything else held.
  """
  @spec ablate(atom()) :: map()
  def ablate(flag), do: %{flag => not Map.fetch!(@defaults, flag)}
end
