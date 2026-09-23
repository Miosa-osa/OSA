defmodule OptimalSystemAgent.Shell.ExitClassifier do
  @moduledoc """
  Classifies a shell command's non-zero exit code as a real failure or a
  BENIGN answer (Claude Code parity).

  A handful of POSIX utilities use exit code 1 to report a normal, meaningful
  outcome rather than an error: `grep`/`egrep`/`fgrep`/`rg` exit 1 means "no
  matches" (a real, trustworthy answer — see the identical reasoning already
  applied to the FOREGROUND `file_grep` tool's ripgrep path), `diff`/`cmp`
  exit 1 means "the inputs differ", and `test`/`[` exit 1 means "the
  expression was false". None of these are failures, but
  `Shell.BackgroundTask` used to mark every non-zero exit `:failed`
  unconditionally — a background `grep -r TODO .` that simply found nothing
  showed the model (and the TUI) a red failure for a correct, negative
  answer.

  ## Scope: only when we can KNOW which program's exit code this is

  The exit status of a shell command is whatever the LAST thing that ran
  reported. That is unambiguous only for:

    * a single simple command (`grep foo file`), or
    * a plain pipeline (`a | b | c` — without `set -o pipefail`, bash reports
      the LAST stage's exit code, so classifying by `c` is correct).

  Any `;`, `&&`, `||`, or backgrounding `&` makes "which program produced
  this code" depend on which branch of the command line actually ran, which
  cannot be determined from the text alone — so those are left unclassified
  (real failures stay `:failed`, exactly today's behaviour) rather than
  guessed at.

  Reuses `Tools.Builtins.ShellExecute.Parser`, the same quote/substitution
  -aware tokenizer `shell_execute` already uses for permission scanning, so
  this never re-implements shell parsing.
  """

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Parser

  # Exit 1 = "no matches" — a real, trustworthy negative answer, not a fault.
  @grep_family ~w(grep egrep fgrep rg)
  # Exit 1 = "the inputs differ" / "files differ".
  @diff_family ~w(diff cmp)
  # Exit 1 = "the expression was false".
  @test_family ~w(test [)

  @doc """
  `true` when `exit_code` is a normal, meaningful (non-failure) outcome for
  `command` — a background command should be reported as COMPLETED, not
  FAILED, when this returns `true`.

  Always `false` for exit code `0` (that path is already "done" upstream) and
  for anything the parser cannot attribute to a single known program.
  """
  @spec benign_exit?(String.t(), integer()) :: boolean()
  def benign_exit?(command, exit_code) when is_binary(command) and exit_code == 1 do
    case last_pipeline_head(command) do
      nil -> false
      head -> benign_head?(head)
    end
  end

  def benign_exit?(_command, _exit_code), do: false

  defp benign_head?(head) do
    head in @grep_family or head in @diff_family or head in @test_family
  end

  # nil when the command mixes in a `;`/`&&`/`||`/`&` connective (ambiguous —
  # see moduledoc) or has no resolvable head; otherwise the basename of the
  # LAST pipeline stage's command (the one whose exit code the shell reports).
  defp last_pipeline_head(command) do
    tokens = Parser.tokenize(command)

    if Enum.any?(tokens, &sequencing_op?/1) do
      nil
    else
      command
      |> Parser.segments()
      |> List.last()
      |> segment_head()
    end
  end

  defp sequencing_op?({:op, op}), do: op in [";", "&&", "||", "&"]
  defp sequencing_op?(_), do: false

  defp segment_head(nil), do: nil

  defp segment_head(tokens) do
    case Enum.find(tokens, &match?({:word, _}, &1)) do
      {:word, raw} ->
        raw
        |> Parser.unquote_token()
        |> Path.basename()

      _ ->
        nil
    end
  end
end
