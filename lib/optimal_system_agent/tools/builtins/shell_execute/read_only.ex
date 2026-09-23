defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.ReadOnly do
  @moduledoc """
  Provable read-only classification for ONE `shell_execute` command line.

  The single source of truth for "is this command line safe to run
  concurrently alongside other calls, or read alongside a write". Two callers
  need the exact same, conservative answer and must never diverge:

    * `Permissions.AutoClassifier` — fast-path `:ask` → `:allow` downgrade
      (opt-in `overdrive`/`auto` mode).
    * `ShellExecute.Tool.concurrency_safe?/2` — tool-dispatch parallel
      batching (`Agent.Loop.ToolOrchestrator`).

  A second, independently-written read-only matcher would be exactly the kind
  of drift this codebase keeps paying down (see `CommandVariants`'s
  moduledoc for the same argument about quoting) — so this is the ONE place.

  ## The rule

  `provably_read_only?/1` is `true` only when ALL of the following hold:

    1. `CommandVariants.fully_analyzed?/1` — the command is small enough and
       every wrapper (`bash -c "…"`, `sudo …`, `env …`, `xargs …`, …) was
       fully unwrapped. A bound on that analysis fails CLOSED: an
       incompletely-analysed command is never read-only.
    2. No command substitution / parameter expansion (`$(...)`, `` ` ``,
       `${...}`) anywhere in the line — these can resolve to an arbitrary
       write at runtime and cannot be judged statically.
    3. No bare background operator (`&`) — the tool call returning does not
       mean the backgrounded work is done, so nothing about it can be
       compared against another call's timing.
    4. EVERY `;` / `&&` / `||` / `|` / `&`-connected segment has a HEAD on
       the read-only allowlist, with per-head exceptions for commands that
       are read-only in SOME invocations and not others (`git` — only
       read-only subcommands; `find`/`fdfind` — no mutating/exec primary;
       `sed`/`awk` — no in-place edit / redirect-looking program text;
       `env` — only the bare/flags-only form that prints the environment,
       never `env VAR=val CMD…`, which runs an arbitrary child command this
       classifier cannot see into).
    5. No `>` / `>>` redirect anywhere (input redirection `<` is fine — it
       cannot write).

  Fail-closed throughout: anything unrecognised, unparsed, oversized, or only
  partially analysed answers `false`. Never raises.
  """

  alias OptimalSystemAgent.Agent.Safety.CommandVariants
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Parser

  # Command heads whose invocation is read-only regardless of (non-flag)
  # arguments — no filesystem/system mutation. Conservative by design:
  # anything not listed here, and not one of the per-head exceptions below,
  # is NOT provably read-only.
  @read_only_heads ~w(
    ls pwd cat head tail wc echo printf grep egrep fgrep rg fd jq
    which type file stat tree basename dirname realpath readlink strings
    date whoami hostname uname nproc printenv true false test
    sort uniq tr cut column comm diff cmp od xxd hexdump nl fold
    df du ps free uptime id groups
  )

  # `git` subcommands that only read repository state.
  @git_read_only ~w(
    status diff log show blame ls-files rev-parse describe merge-base
    show-ref reflog shortlog cat-file for-each-ref whatchanged ls-tree
    rev-list name-rev symbolic-ref var count-objects
  )

  # `find` primaries that mutate/execute — their presence disqualifies a
  # `find` segment (mirrors grok's find_is_read_only).
  @find_mutating ~w(-delete -exec -execdir -ok -okdir -fprint -fprint0 -fprintf -fls)

  @doc """
  Is `command` provably read-only?

  `false` on anything unrecognised, oversized, dynamically-resolved, or
  containing so much as one non-read-only segment. Never raises.
  """
  @spec provably_read_only?(term()) :: boolean()
  def provably_read_only?(command) when is_binary(command) and command != "" do
    cond do
      not CommandVariants.fully_analyzed?(command) ->
        false

      String.contains?(command, "$(") or String.contains?(command, "`") or
          String.contains?(command, "${") ->
        false

      background?(Parser.tokenize(command)) ->
        false

      true ->
        segments = Parser.segments(command)

        segments != [] and not write_redirect?(segments) and
          Enum.all?(segments, &segment_read_only?/1)
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def provably_read_only?(_), do: false

  # ── Background detection ──────────────────────────────────────────────

  # A bare `&` (not `&&`) backgrounds its preceding pipeline. Segment
  # splitting already drops the operator tokens, so this is checked
  # separately against the raw token stream.
  defp background?(tokens), do: Enum.any?(tokens, &match?({:op, "&"}, &1))

  # ── Segment analysis ──────────────────────────────────────────────────

  defp write_redirect?(segments) do
    Enum.any?(segments, fn tokens ->
      Enum.any?(tokens, fn
        {:redir, op} -> op in [">", ">>"]
        _ -> false
      end)
    end)
  end

  defp segment_read_only?(tokens) do
    words = for {:word, w} <- tokens, do: unquote_word(w)

    case words do
      [] -> false
      [head_raw | rest] -> head_raw |> normalize_head() |> head_read_only?(rest)
    end
  end

  defp normalize_head(head_raw), do: head_raw |> String.replace(~r/^\\+/, "") |> Path.basename()

  defp head_read_only?("git", args), do: git_read_only?(args)
  defp head_read_only?("find", args), do: not Enum.any?(args, &(&1 in @find_mutating))

  defp head_read_only?("fdfind", args),
    do: not Enum.any?(args, &(&1 in ["-x", "--exec", "-X", "--exec-batch"]))

  # `sed -i` / `sed --in-place` edits files in place — not read-only.
  defp head_read_only?("sed", args) do
    not Enum.any?(args, fn a -> a == "-i" or String.starts_with?(a, "-i") or a == "--in-place" end)
  end

  # awk can write via its program text; only allow when nothing looks like a
  # redirect/print-to-file directive. Conservative: any arg mentioning '>' defers.
  defp head_read_only?("awk", args) do
    not Enum.any?(args, &String.contains?(&1, ">"))
  end

  # `env` alone (optionally with flags, e.g. `env -0`) prints the
  # environment — read-only. `env VAR=val CMD…` spawns an arbitrary child
  # command this classifier cannot see into, so ANY non-flag argument
  # disqualifies it.
  defp head_read_only?("env", args), do: Enum.all?(args, &flag?/1)

  defp head_read_only?(head, _args), do: head in @read_only_heads

  defp git_read_only?(args) do
    case Enum.find(args, fn a -> not String.starts_with?(a, "-") end) do
      nil -> false
      sub -> sub in @git_read_only
    end
  end

  defp flag?(v), do: String.starts_with?(v, "-")

  defp unquote_word(w), do: Parser.unquote_token(w)
end
