defmodule OptimalSystemAgent.Agent.Loop.SpotCheckAuditor do
  @moduledoc """
  Cheap, sporadic spot-checks — the VSM System-3* audit tier.

  ## The problem this replaces

  The goal-completion verifier (`Agent.Loop.GoalVerifier`) closed the biggest
  judgment gap in the harness — a completion claim was previously accepted
  from the same model that wrote the code — by spawning N independent,
  read-only skeptic subagents to re-review the work. That panel is
  deliberately expensive (a full LLM session per skeptic), and on one observed
  engagement it spent 29+ actions and $2.61 RE-READING A WHOLE REPOSITORY to
  verify a change the harness's own tool-call ledger (`VerificationEvidence`)
  had already, factually, recorded: which files were written, which
  build/test commands ran, and whether they passed.

  This module is the cheaper tier that sits in front of that panel. Given the
  diff, the acceptance criteria, and the agent's own evidence ledger, it:

    1. checks a SAMPLED SUBSET of the agent's claims DIRECTLY — does the
       claimed-written file actually exist on disk right now, do the diff's
       added lines actually appear in it, does the latest recorded test/build
       command still pass when re-run — using only local file/ETS reads and,
       for at most one command, a single bounded subprocess. No LLM call, no
       subagent, no repository crawl.
    2. escalates to the expensive panel ONLY when a spot check actually FAILS
       (a claimed file is missing, a hunk doesn't match, a rerun goes red) OR
       the change is judged too risky for a 2-3-sample check to represent
       fairly (a large, untested change; a security-sensitive path; nothing
       in the ledger that could be sampled at all).

  Cost, in the common case where the ledger already supports the claim: ZERO
  LLM calls and zero subagents, versus N full skeptic sessions every time. The
  panel remains exactly as strict as before on every path that reaches it —
  this module only decides WHETHER to pay for it, mirroring how
  `GoalVerifier.triage/1` already decides whether the panel is worth spending
  at all; this is the additional, cheaper-still tier between that triage call
  and the panel.

  ## Cap and log

  Every call is capped (`:max_samples`, default #{3}; at most one command
  rerun) and every call emits `:spot_check_audit` on `Events.Bus` naming
  exactly what was checked and why the verdict came out the way it did — so
  the audit is auditable, not just cheap.

  This module is generic: it does not know about the panel, the goal loop, or
  anything else Elixir on the other side of a `:fail` verdict. Callers decide
  what "fail" means for them — `GoalVerifier` escalates to its skeptic panel;
  a subagent reporting its own result to a parent (VSM item 9) instead
  annotates the result and reports pain, since spawning ANOTHER panel from
  inside a delegated child is exactly the runaway-recursion shape item 9
  exists to prevent.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Loop.VerificationEvidence, as: Ledger
  alias OptimalSystemAgent.Events.Bus

  defmodule Check do
    @moduledoc "One sampled claim and how it was verified."
    @type result :: :confirmed | :contradicted | :unverifiable
    @type t :: %__MODULE__{
            claim: String.t(),
            method: atom(),
            result: result(),
            detail: String.t()
          }
    defstruct [:claim, :method, :result, :detail]
  end

  defmodule Report do
    @moduledoc "What the spot check looked at and concluded."
    @type t :: %__MODULE__{
            checked: [Check.t()],
            risk: :low | :high,
            evidence_count: non_neg_integer()
          }
    defstruct checked: [], risk: :low, evidence_count: 0
  end

  @default_max_samples 3
  @default_rerun_timeout_ms 20_000

  # A written/changed path matching this — or a diff whose header names one —
  # is inherently too consequential for a 2-3-sample check to vouch for; the
  # full panel's adversarial review is worth paying for regardless of what the
  # ledger happens to show.
  @sensitive_path_re ~r/(auth|secret|credential|token|password|crypto|encrypt|permission|security)/i

  # A diff past either bound cannot be fairly represented by a small sample —
  # escalate rather than spot-check a slice of it and call the rest "checked".
  @large_diff_bytes 40_000
  @large_diff_files 12

  # Rerunning an ad-hoc probe or a slow suite is not "cheap" — only a command
  # that clearly names a fast, standard test runner is ever re-executed.
  @rerunnable_command_re ~r/\b(mix\s+test|(npm|pnpm|yarn|bun)\s+(run\s+)?test|go\s+test|cargo\s+(test|nextest)|pytest|py\.test)\b/

  @doc """
  Spot-check `session_id`'s evidence ledger.

  Returns `{:pass, report}` when the sampled claims held up and the change
  did not look too risky for a sample to represent, or `{:fail, reason,
  report}` when a claim was directly contradicted or the risk was judged too
  high to vouch for at this sample size.

  Options:

    * `:diff`        — the accumulated diff, for the sensitive-path and
      diff-size risk checks and for cross-reading a sampled file's added
      lines against its current disk content. Defaults to `""` (skips the
      diff-dependent checks — a caller with no diff still gets the
      ledger-only and file-existence checks).
    * `:criteria`     — the acceptance criteria / founding request text, used
      only as an additional risk signal (a large change with no stated
      criteria to check completeness against is weak grounding) and echoed on
      the logged event for context. Never itself LLM-judged — that would
      defeat the point of a cheap tier.
    * `:max_samples`  — cap on sampled claims (default #{@default_max_samples}).
    * `:allow_rerun?` — whether a command rerun is permitted at all (default
      `true`). A caller auditing a NESTED subagent's own result may want to
      disable this to keep the self-check side-effect-free.
  """
  @spec spot_check(String.t() | nil, keyword()) ::
          {:pass, Report.t()} | {:fail, String.t(), Report.t()}
  def spot_check(session_id, opts \\ [])

  def spot_check(session_id, opts) when is_binary(session_id) and session_id != "" do
    entries = Ledger.entries(session_id)

    if entries == [] do
      report = %Report{checked: [], risk: :high, evidence_count: 0}
      finish(session_id, :fail, "no evidence ledger entries to spot-check", report, opts)
    else
      diff = Keyword.get(opts, :diff, "")
      criteria = Keyword.get(opts, :criteria, "")
      max_samples = Keyword.get(opts, :max_samples, @default_max_samples)
      allow_rerun? = Keyword.get(opts, :allow_rerun?, true)

      checked = run_checks(session_id, entries, diff, max_samples, allow_rerun?)
      risk = assess_risk(session_id, entries, diff, criteria, checked)
      report = %Report{checked: checked, risk: risk, evidence_count: length(entries)}

      case Enum.find(checked, &(&1.result == :contradicted)) do
        %Check{} = failed ->
          finish(session_id, :fail, failed.detail, report, opts)

        nil ->
          if risk == :high do
            finish(session_id, :fail, risk_reason(entries, diff, criteria, checked), report, opts)
          else
            finish(
              session_id,
              :pass,
              "#{length(checked)} claim(s) spot-checked, none contradicted",
              report,
              opts
            )
          end
      end
    end
  end

  def spot_check(_session_id, _opts) do
    report = %Report{checked: [], risk: :high, evidence_count: 0}
    {:fail, "no session to audit", report}
  end

  # ── Checks ──────────────────────────────────────────────────────────

  defp run_checks(session_id, entries, diff, max_samples, allow_rerun?) do
    ledger_checks = ledger_adequacy_checks(session_id)
    budget = max(max_samples - length(ledger_checks), 0)

    sampled_paths = sample_written_paths(entries, budget)
    existence_checks = Enum.map(sampled_paths, &file_exists_check/1)

    diff_checks =
      sampled_paths
      |> Enum.zip(existence_checks)
      |> Enum.filter(fn {_p, c} -> c.result == :confirmed end)
      |> Enum.map(fn {p, _c} -> diff_match_check(p, diff) end)
      |> Enum.reject(&is_nil/1)

    rerun_checks =
      if allow_rerun? and length(ledger_checks) < max_samples do
        List.wrap(rerun_check(entries))
      else
        []
      end

    ledger_checks ++ existence_checks ++ diff_checks ++ rerun_checks
  end

  # Zero-cost: the ledger already knows whether every write this session made
  # has a passing check covering it, and whether the last check to run after a
  # write actually failed and was never superseded. Reusing these (rather than
  # re-deriving the same facts) means the common "the model claimed done but
  # never actually tested it" case is caught with no I/O at all.
  defp ledger_adequacy_checks(session_id) do
    pending =
      case Ledger.pending_files(session_id) do
        [] ->
          []

        paths ->
          [
            %Check{
              claim: "every write has a passing check covering it",
              method: :ledger_coverage,
              result: :contradicted,
              detail:
                "#{length(paths)} written file(s) have no passing check since their last " <>
                  "write: #{Enum.join(Enum.take(paths, 5), ", ")}"
            }
          ]
      end

    failing =
      case Ledger.failing_check_since_write(session_id) do
        nil ->
          []

        entry ->
          cmd = Map.get(entry, :command) || Map.get(entry, :tool) || "a check"

          [
            %Check{
              claim: "the latest check passed",
              method: :ledger_check,
              result: :contradicted,
              detail: "`#{cmd}` failed and was never superseded by a later passing run"
            }
          ]
      end

    # A check that specifically RAN and FAILED is a more actionable signal
    # than "nothing has covered this yet" — both can be true of the same
    # write (a failed check does not count as coverage either), so when both
    # fire, the failing-check finding leads.
    failing ++ pending
  rescue
    _ -> []
  end

  # Distinct, most-recently-written paths first — the freshest claims are the
  # ones most worth corroborating.
  defp sample_written_paths(entries, n) when n > 0 do
    entries
    |> Enum.filter(&(Map.get(&1, :kind) == :write and Map.get(&1, :success) == true))
    |> Enum.reverse()
    |> Enum.flat_map(fn e -> List.wrap(Map.get(e, :written_paths, [])) end)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.take(n)
  end

  defp sample_written_paths(_entries, _n), do: []

  defp file_exists_check(path) do
    if File.exists?(path) do
      %Check{claim: "wrote #{path}", method: :file_exists, result: :confirmed, detail: path}
    else
      %Check{
        claim: "wrote #{path}",
        method: :file_exists,
        result: :contradicted,
        detail: "#{path} was recorded as written but does not exist on disk"
      }
    end
  rescue
    _ ->
      %Check{claim: "wrote #{path}", method: :file_exists, result: :unverifiable, detail: path}
  end

  # Cross-read: does the diff's own hunk for this path have at least one
  # non-trivial "+" line that is actually present in the file's current
  # content? Catches a diff that no longer matches disk (a later revert, an
  # edit made outside the recorded tool calls) without needing an LLM to judge
  # it. Returns `nil` (no check performed, not a claim) when the diff carries
  # no hunk for this path at all — that is not itself suspicious; the file may
  # have been created via a tool the diff-hunk parser cannot see (e.g. an
  # already-committed change).
  defp diff_match_check(path, diff) when is_binary(diff) and diff != "" do
    case hunk_added_lines(path, diff) do
      [] ->
        nil

      added_lines ->
        case File.read(path) do
          {:ok, content} ->
            if Enum.any?(added_lines, &String.contains?(content, &1)) do
              %Check{
                claim: "diff-claimed content for #{path} is present",
                method: :diff_match,
                result: :confirmed,
                detail: path
              }
            else
              %Check{
                claim: "diff-claimed content for #{path} is present",
                method: :diff_match,
                result: :contradicted,
                detail:
                  "#{path}'s current content does not contain any of the diff's added lines " <>
                    "for it — the diff may be stale or the change may have been reverted"
              }
            end

          {:error, _} ->
            %Check{
              claim: "diff-claimed content for #{path} is present",
              method: :diff_match,
              result: :unverifiable,
              detail: path
            }
        end
    end
  rescue
    _ ->
      %Check{
        claim: "diff-claimed content for #{path} is present",
        method: :diff_match,
        result: :unverifiable,
        detail: path
      }
  end

  defp diff_match_check(_path, _diff), do: nil

  # Meaningful "+" lines (not blank, not a lone brace/paren) from the FIRST
  # hunk in the diff whose header names `path` (by basename — the diff may use
  # a different root prefix than the absolute path the ledger recorded).
  defp hunk_added_lines(path, diff) do
    base = Path.basename(path)

    # Zero-width split BEFORE each `diff --git` header (rather than a
    # consuming split) so the header line stays attached to the section that
    # follows it — otherwise the one place the filename is actually named
    # gets thrown away by the split itself, and no section could ever match.
    diff
    |> String.split(~r/(?=^diff --git )/m)
    |> Enum.find(&String.contains?(&1, base))
    |> case do
      nil ->
        []

      section ->
        section
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "+"))
        |> Enum.map(&String.trim_leading(&1, "+"))
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(byte_size(&1) > 8))
        |> Enum.take(5)
    end
  end

  # Rerun the LATEST recorded test command, if any, and only if it is a
  # standard, fast test-runner invocation — never an ad-hoc probe, never a
  # full/slow suite the pattern can't recognize as bounded.
  defp rerun_check(entries) do
    entries
    |> Enum.filter(&(Map.get(&1, :kind) == :check and Map.get(&1, :test_command) == true))
    |> List.last()
    |> case do
      nil ->
        nil

      %{command: cmd} when is_binary(cmd) ->
        if Regex.match?(@rerunnable_command_re, cmd) do
          rerun(cmd)
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp rerun(cmd) do
    case call_rerun_runner(cmd) do
      {:ok, 0} ->
        %Check{claim: "`#{cmd}` passes", method: :rerun, result: :confirmed, detail: cmd}

      {:ok, code} ->
        %Check{
          claim: "`#{cmd}` passes",
          method: :rerun,
          result: :contradicted,
          detail: "`#{cmd}` was re-run and exited #{code}"
        }

      {:error, reason} ->
        %Check{
          claim: "`#{cmd}` passes",
          method: :rerun,
          result: :unverifiable,
          detail: "rerun of `#{cmd}` did not complete: #{inspect(reason)}"
        }
    end
  end

  # Injectable for tests via `:spot_check_command_runner` — `fn cmd -> {:ok,
  # exit_code} | {:error, reason} end` — so a unit test never actually shells
  # out. Production default runs the command with a hard, bounded timeout
  # (mirrors `GoalVerifier.call_triage/1`'s own Task-based wrapper) so a slow
  # rerun degrades to `:unverifiable` rather than blocking the audit.
  defp call_rerun_runner(cmd) do
    runner =
      Application.get_env(
        :optimal_system_agent,
        :spot_check_command_runner,
        &default_rerun/1
      )

    task =
      Task.async(fn ->
        try do
          runner.(cmd)
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, rerun_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp default_rerun(cmd) do
    {_output, code} = System.cmd("sh", ["-c", cmd], stderr_to_stdout: true)
    {:ok, code}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp rerun_timeout_ms do
    Application.get_env(
      :optimal_system_agent,
      :spot_check_rerun_timeout_ms,
      @default_rerun_timeout_ms
    )
  end

  # ── Risk ────────────────────────────────────────────────────────────

  defp assess_risk(session_id, entries, diff, criteria, checked) do
    cond do
      sensitive_change?(entries, diff) ->
        :high

      large_untested_change?(session_id, entries, criteria) ->
        :high

      large_diff?(diff) ->
        :high

      checked != [] and Enum.all?(checked, &(&1.result != :confirmed)) ->
        :high

      true ->
        :low
    end
  end

  defp sensitive_change?(entries, diff) do
    written =
      entries
      |> Enum.filter(&(Map.get(&1, :kind) == :write and Map.get(&1, :success) == true))
      |> Enum.flat_map(fn e -> List.wrap(Map.get(e, :written_paths, [])) end)

    Enum.any?(written, &Regex.match?(@sensitive_path_re, &1)) or
      (is_binary(diff) and Regex.match?(@sensitive_path_re, diff_headers(diff)))
  end

  defp diff_headers(diff) do
    diff
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "diff --git"))
    |> Enum.join("\n")
  end

  # A `:large` change (per the ledger's own proportionality read — whole-file
  # writes, more than one file, or more than 20 lines) with NO discriminating
  # test evidence, and no stated acceptance criteria to weigh completeness
  # against either, is exactly the shape a 2-3-sample spot check cannot fairly
  # vouch for.
  defp large_untested_change?(session_id, entries, criteria) do
    Ledger.change_scale(entries) == :large and
      Ledger.needs_discriminating_test?(session_id) and
      String.trim(to_string(criteria)) == ""
  end

  defp large_diff?(diff) when is_binary(diff) do
    byte_size(diff) > @large_diff_bytes or diff_file_count(diff) > @large_diff_files
  end

  defp large_diff?(_diff), do: false

  defp diff_file_count(diff) do
    diff
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, "diff --git"))
  end

  defp risk_reason(entries, diff, criteria, checked) do
    cond do
      sensitive_change?(entries, diff) ->
        "the change touches a security/credential-sensitive path — too consequential for a " <>
          "sampled spot check to vouch for"

      large_diff?(diff) ->
        "the diff is too large for a #{@default_max_samples}-sample check to fairly represent"

      checked != [] and Enum.all?(checked, &(&1.result != :confirmed)) ->
        "nothing sampled could actually be corroborated"

      true ->
        "a large, untested change with no stated acceptance criteria — " <>
          "#{if String.trim(to_string(criteria)) == "", do: "and no criteria to weigh completeness against", else: "escalating"}"
    end
  end

  # ── Logging ─────────────────────────────────────────────────────────

  defp finish(session_id, verdict, reason, report, opts) do
    Bus.emit(:system_event, %{
      event: :spot_check_audit,
      session_id: session_id,
      verdict: verdict,
      reason: reason,
      risk: report.risk,
      evidence_count: report.evidence_count,
      checked:
        Enum.map(report.checked, fn c ->
          %{claim: c.claim, method: c.method, result: c.result}
        end),
      criteria_present: String.trim(to_string(Keyword.get(opts, :criteria, ""))) != ""
    })

    Logger.info(
      "[spot-check] session=#{inspect(session_id)} verdict=#{verdict} " <>
        "checked=#{length(report.checked)} risk=#{report.risk} reason=#{inspect(reason)}"
    )

    case verdict do
      :pass -> {:pass, report}
      :fail -> {:fail, reason, report}
    end
  end
end
