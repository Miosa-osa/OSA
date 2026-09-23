defmodule OptimalSystemAgent.Agent.Safety.DangerousCommands do
  @moduledoc """
  POLICY DATA: the circuit-breaker blocklist, in three severity classes.

  This module is the last line of defence. Unlike the auto-mode `Rules`
  (which are risk-tiered — `:caution`/`:dangerous` verdicts that the Guardian
  may *allow*, block, or pause depending on the session's permission tier), the
  patterns here are blocked **in every permission tier**, with exactly the
  documented exceptions described below. There is no counter, no
  pause-after-N, no allowlist, no config toggle.

  ## The three classes, and why there are three

  A breaker that blocks work the operator explicitly authorised is not a safety
  feature — it is a bug that teaches people to switch the breaker off. Overdrive
  ("full auto, stop asking me") is an explicit, deliberate operator statement,
  so the blocklist is split by *what happens if the command runs and the
  operator was wrong*:

    * `:catastrophic` — **never overridable, in any mode, ever.** The damage is
      unbounded and unrecoverable from inside the session: the machine, its
      filesystem, or a database is destroyed, and no amount of operator intent
      makes that a thing OSA should do on its behalf. `rm -rf /`, fork bombs,
      `dd` to a block device, `mkfs`, `DROP DATABASE`, `TRUNCATE` on prod.

    * `:confirm_required` — **always prompts, in every mode, overdrive
      included — but is never hard-blocked either.** The target of a recursive
      force delete that the breaker cannot statically resolve: a command
      substitution (`$(pwd)`, `` `git rev-parse --show-toplevel` ``), a brace
      parameter expansion (`${DIR}`), or a glob anchored at/near a filesystem
      root (`/etc/*`, `$HOME/*`). The breaker cannot prove such a target is `/`
      any more than it can prove it is `./build` — silently deciding either way
      (hard-block *or* allow) is a guess with an unrecoverable downside, so
      neither guess is made: the operator is asked, in every mode, and
      `overdrive` does not waive the question the way it waives `:overridable`.
      Claude Code shipped the equivalent fix in 2.1.281.

    * `:overridable` — **blocked in every mode EXCEPT `:overdrive`/`:bypass`.**
      These are genuinely risky *conventions*, not destruction: the blast radius
      is bounded, recoverable, and frequently the literal task the operator
      asked for. Force-pushing a protected branch is recoverable via reflog and
      is routine in a throwaway container or a personal repo; `curl … | sh` is
      how a large share of the world's software installs itself. Blocking these
      under overdrive leaves the operator with a refusal, no recourse, and no
      way to say "yes, that is what I meant" — which is what
      `configure-git-webserver` hit four times in Terminal-Bench.

  Enforcement of that distinction lives in ONE place —
  `OptimalSystemAgent.Agent.Loop.ToolExecutor.approve_tool_call/2` — which
  consults `classify/1`. Every other caller uses `blocked?/1` / `check_command/1`
  and gets the strict, mode-independent verdict (every class blocked), because
  those callers have no permission mode to reason about.

  Separation of concerns:

    * `Rules` / `Classifier` / `Guardian` — the *allowable* risk-tiered
      auto-mode safety policy. Tier-dependent enforcement.
    * `DangerousCommands` (this module) — the *never, under any circumstances*
      subset. Tier-independent enforcement, wired as the FIRST clause of the
      tool-execution boundary so it cannot be bypassed.

  It is **pure**: no I/O, no state, no config reads. `blocked?/1` returns
  `{:blocked, reason}` or `:ok`.

  ## Quoting and wrappers

  Every pattern below is evaluated against the **variant set** of the command
  (`CommandVariants.variants/1`), not against the raw string. The shell strips
  quoting and unwraps `bash -c` before the kernel runs anything, so a matcher
  that reads the raw string is matching a different program than the one that
  executes — which is how `rm -rf "/"`, `"rm" -rf /`, `rm -rf \\/` and
  `bash -c "rm -rf /"` all used to walk straight through a breaker that stopped
  the bare `rm -rf /`. Normalizing the input is the only fix that generalizes;
  hardening the regexes loses to the next encoding.

  ## What is blocked

  `:catastrophic` (never overridable):

    * `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`, `rm -rf $PWD`, `rm -rf $OLDPWD`,
      `rm -rf /*`, `rm -rf .` and other recursive-force deletes rooted at a
      literal broad root.
    * Fork bombs (`:(){ :|:& };:` and obfuscated variants).
    * `dd` writing to a block device (`of=/dev/sda`, `/dev/nvme…`, `/dev/disk…`).
    * `mkfs` / filesystem creation on any device.
    * `DROP DATABASE` / `DROP SCHEMA`.
    * `DROP TABLE` / `TRUNCATE` targeting a production database/table.
    * `file_delete` on a root/home path.

  `:confirm_required` (always prompts, overdrive included; never silently
  allowed or hard-blocked):

    * `rm -rf "$(pwd)"`, `` rm -rf `git rev-parse --show-toplevel` ``,
      `rm -rf "${SOME_VAR}"` — a recursive delete whose target is a command
      substitution or brace parameter expansion.
    * `rm -rf $DIR/`, `rm -rf "$DIR"`, `rm -rf $TARGET`, `rm -r "$BUILD_DIR"`
      — a recursive delete whose target is a bare or positional shell
      variable. `$DIR/` with `DIR` unset or empty IS `rm -rf /`; force (`-f`)
      is not required to reach this class.
    * `rm -rf /etc/*`, `rm -rf "$HOME"/*` — a recursive delete whose target
      is a glob anchored at, or one segment below, a filesystem root.
    * `find "$DIR" -delete`, `find . -name "$PAT" -exec rm {} \;` — the same
      class via `find`'s own destructive primaries.

  `:overridable` (blocked everywhere except overdrive/bypass):

    * `git push --force` / `-f` / `+ref` to a protected branch
      (main, master, production, release, develop, staging, prod).
    * Pipe-to-shell of downloaded content (`curl … | sh`, `wget … | bash`,
      `curl … | sudo sh`).
  """

  alias OptimalSystemAgent.Agent.Safety.CommandVariants

  @type reason :: String.t()
  @type result :: {:blocked, reason()} | :ok

  @typedoc """
  Severity class of a breaker match.

    * `:catastrophic` — unrecoverable destruction. Blocked in EVERY mode.
    * `:confirm_required` — the target cannot be statically proven safe OR
      unsafe (a command substitution, backtick, brace expansion, or a glob
      at/near a filesystem root). Always prompts, in EVERY mode — overdrive
      included — and is never silently allowed or hard-blocked.
    * `:overridable` — bounded, recoverable risk. Blocked in every mode except
      `:overdrive`/`:bypass`, where the operator has taken explicit
      responsibility for unattended execution.
  """
  @type severity :: :catastrophic | :confirm_required | :overridable
  @type classified :: {:blocked, reason(), severity()} | :ok

  # Tool names whose primary argument is a shell command string.
  @shell_tools ~w(shell_execute shell run_command bash code_sandbox repl)

  # Tool names that delete files/paths (primary argument is a path).
  @delete_tools ~w(file_delete)

  # Protected git branches — force-pushing to any of these is a hard stop.
  @protected_branches ~w(main master production prod release develop staging)

  # ── rm -rf broad roots ──────────────────────────────────────────────
  # Detected in three independent, order-insensitive parts (all must hold):
  #   1. an `rm` invocation (incl. `\rm` alias-bypass, or a path like /bin/rm)
  #   2. a recursive flag present anywhere (a `-…r…` token or --recursive)
  #   3. a force flag present anywhere (a `-…f…` token or --force)
  # …targeting a BROAD ROOT that is a *complete* argument (bounded on both
  # sides), so scoped paths like `rm -rf ./build` or `rm -rf /home/x/tmp`
  # are NOT matched.
  @rm_invocation ~r/(?:^|[\s;&|(`])\\?(?:\/\S+\/)?rm\b/i
  @rm_recursive_flag ~r/\brm\b[^\n]*\s-\w*r|\brm\b[^\n]*\s--recursive\b/i
  @rm_force_flag ~r/\brm\b[^\n]*\s-\w*f|\brm\b[^\n]*\s--force\b/i

  # A broad root target: /, /*, ~, ~/, ~/*, $HOME/$PWD/$OLDPWD (opt /), ., ..,
  # *, or a bare top-level system directory (/etc, /usr, /home, …). Must be
  # delimited so it is the whole argument, not a prefix of a deeper, scoped
  # path. $PWD/$OLDPWD sit beside $HOME here (not in the unresolvable-target
  # class below) because, like $HOME, their *meaning* is not in doubt — they
  # denote the whole current/previous working directory, the same breadth as
  # the bare `.` two rows down, not an opaque value only the shell can
  # resolve.
  @broad_root_target ~r/(?:^|\s)(?:\/|\/\*|~|~\/|~\/\*|\$\{?HOME\}?\/?|\$\{?PWD\}?\/?|\$\{?OLDPWD\}?\/?|\.|\.\.|\*|\/(?:etc|usr|bin|sbin|boot|dev|lib|lib64|proc|root|run|sys|var|opt|home|Users|System|Library))(?=[\s;&|)]|$)/

  # ── rm -rf UNRESOLVABLE target ──────────────────────────────────────
  #
  # `rm_rf_broad_root?/1` above only fires when the delete target is a
  # LITERAL, complete argument sitting right there in the command line. A
  # target built from a command substitution (`$(pwd)`, `` `git rev-parse
  # --show-toplevel` ``), a brace parameter expansion (`${DIR}`), or a glob
  # anchored at/near a filesystem root (`/etc/*`, `$HOME/*`) is resolved only
  # by the SHELL, at run time — the breaker can prove `./build` is scoped and
  # `/` is not, but it cannot prove anything about a value it never sees.
  # Guessing either way (hard-block, which would refuse plenty of innocent
  # commands, or silently allow, which is the gap this class closes) is wrong
  # with an unrecoverable downside on one side, so `check_variant/1` reports
  # `:confirm_required` instead of `:catastrophic`/`:overridable`/`:ok` and
  # `ToolExecutor.approve_tool_call/2` turns that into an interactive prompt
  # in EVERY permission mode, overdrive included.

  # A shell expansion whose VALUE is unknown without running the shell:
  # command substitution (`$(...)`), backtick substitution, brace parameter
  # expansion (`${NAME}`), a bare NAMED variable (`$DIR`, `$BUILD_DIR`), or a
  # positional/special parameter (`$1`, `$@`, `$*`, `$#`, `$?`, `$$`, `$!`,
  # `$-`). `$DIR/` with `DIR` unset or empty is literally `rm -rf /` — the
  # single most important case of this whole class — and it matched NOTHING
  # here before: only `$(...)`/backtick/`${...}` were covered, so `rm -rf
  # $DIR/`, `rm -rf "$DIR"`, `rm -rf $TARGET` all read as :ok and ran
  # unprompted under overdrive. Bounded to the start of a shell word (after
  # whitespace, a quote, or the start of the remaining text) so a `$`
  # embedded mid-token (not a real expansion) is not what this matches.
  #
  # The bare-`$HOME`/`$PWD`/`$OLDPWD` literal-whole-argument case is NOT
  # excluded from this alternation on purpose: `check_variant/1`'s cond checks
  # every `:catastrophic` clause (including `rm_rf_broad_root?/1`, which DOES
  # match that exact case) before this one, so it still reports
  # `:catastrophic`, never downgraded to `:confirm_required` by also matching
  # here — see the ORDER IS LOAD-BEARING note on `check_variant/1`.
  @dynamic_expansion_source "(?:^|[\\s\"'])(?:\\$\\(|`|\\$\\{|\\$[A-Za-z_][A-Za-z0-9_]*|\\$[0-9@*#?$!-])"
  @dynamic_expansion Regex.compile!(@dynamic_expansion_source)

  # Command substitution / backtick / brace-expansion / bare or positional
  # variable anywhere after an `rm` invocation: the delete target depends on
  # a value only known once the shell has already evaluated something else.
  # Built from `@dynamic_expansion_source` (not a second, hand-copied
  # alternation) so the two can never drift apart.
  @rm_dynamic_target Regex.compile!("\\brm\\b[^\\n]*" <> @dynamic_expansion_source, "i")

  # A delete target that is a glob anchored at, or one path segment below, a
  # filesystem root — `/etc/*`, `$HOME/*`, `${HOME}/*`, `$PWD/*` — not already
  # caught by `@broad_root_target` (which matches the bare directory only, no
  # glob suffix). Bounded the same way broad_root_target is: the glob must be
  # a complete argument, not a prefix of a deeper path.
  @rm_near_root_glob ~r/(?:^|\s)(?:\/(?:etc|usr|bin|sbin|boot|dev|lib|lib64|proc|root|run|sys|var|opt|home|Users|System|Library)\/\*|\$\{?HOME\}?\/\*|\$\{?PWD\}?\/\*|\$\{?OLDPWD\}?\/\*)(?=[\s;&|)]|$)/i

  # `find … -delete` / `find … -exec rm …` whose command line ALSO carries a
  # dynamic expansion — same reasoning, via find's own destructive primaries
  # instead of rm's. Independent, order-insensitive parts, like the rm checks:
  # the destructive primary and the expansion may appear on either side of it
  # (`find "$DIR" -delete`, `find . -name "$PAT" -delete`).
  @find_destructive_primary ~r/\bfind\b[^\n]*(?:-delete\b|-exec\s+\\?rm\b)/i

  # ── force push to protected branch ──────────────────────────────────
  @force_push_flag ~r/\bgit\s+push\b[^\n]*(?:--force\b(?!-with-lease)|--force-with-lease\b|(?:^|\s)-\w*f\w*\b|\s\+[\w\/.-]+)/i

  # ── fork bomb ───────────────────────────────────────────────────────
  # Classic `:(){ :|:& };:` and single-char-function variants like
  # `b(){ b|b& };b`: a function definition whose body pipes itself and
  # backgrounds. Paired with `fork_bomb?/1`, which applies the
  # pipes-and-backgrounds test to the captured body.
  #
  # BOUNDED ON PURPOSE. The obvious spelling of this pattern —
  #
  #     ~r/(\S+)\s*\(\s*\)\s*\{[^}]*\|[^}]*&[^}]*\}\s*;?\s*\1?/
  #
  # — is quadratic twice over, and was a ReDoS in the safety gate itself:
  #
  #   * `\S+` rescans the whole remaining input from every start offset, so a
  #     long run of non-space padding costs O(n²). Measured on OTP 26.2.5:
  #     2.5 s for 25 KB of `#`.
  #   * the three unbounded `[^}]*` runs try every split of a body that has no
  #     closing `}`. Measured: 1.2 s for a 6 KB unterminated body.
  #
  # `CommandVariants.variants/1` hands this up to `@max_variants * 2` strings
  # of up to 20 KB each, so `catastrophic_destruction?/1` on a padded command
  # ran for tens of seconds — enough to blow ExUnit's 60 s timeout in CI, and,
  # far worse, to stall the tool-approval path on any large command. A safety
  # gate that an oversized input can hang is a denial of service on the gate.
  #
  # The rewrite is linear and cannot match less than the old one did:
  #
  #   * `\S{1,64}` — the pattern is unanchored, so if any run of non-space
  #     characters reaches the `(`, then a start offset within 64 bytes of that
  #     `(` reaches it too. The name was only ever read back by an OPTIONAL
  #     backreference, so nothing depended on which characters landed in it.
  #   * `\{([^}]*)\}` — `[^}]*` cannot cross a `}`, so the body is uniquely
  #     determined and matching it never backtracks. Moving the `|`/`&` test
  #     into `fork_bomb?/1` also makes it STRICTER-in-coverage: every function
  #     body in the command is examined rather than only those where a `|`
  #     happens to precede a `&`.
  @fork_bomb ~r/\S{1,64}\s*\(\s*\)\s*\{([^}]*)\}/

  # ── dd to a block device ────────────────────────────────────────────
  @dd_block_device ~r/\bdd\b[^\n]*\bof=\/dev\/(?:sd|nvme|hd|vd|disk|mmcblk|xvd|loop)/i

  # ── mkfs ────────────────────────────────────────────────────────────
  @mkfs ~r/\bmkfs(?:\.\w+)?\b[^\n]*\/dev\/|\bmkfs(?:\.\w+)?\s+\/dev\//i

  # ── DROP DATABASE / TRUNCATE on prod ────────────────────────────────
  # Any DROP DATABASE / DROP SCHEMA is a hard stop. TRUNCATE and
  # DROP TABLE are hard-blocked only when a prod-ish identifier is present.
  @drop_database ~r/\bDROP\s+(?:DATABASE|SCHEMA)\b/i
  @drop_truncate_prod ~r/\b(?:DROP\s+TABLE|TRUNCATE(?:\s+TABLE)?)\b[^\n]*\b(?:prod|production|prd|live)\w*/i

  # ── pipe-to-shell ───────────────────────────────────────────────────
  # curl/wget (fetching remote content) piped into a shell interpreter.
  @pipe_to_shell ~r/\b(?:curl|wget|fetch)\b[^\n|]*\|[^\n]*\b(?:sudo\s+)?(?:sh|bash|zsh|dash|ksh|fish|python[23]?|perl|ruby|node)\b/i

  @doc """
  Circuit-breaker check. Accepts either:

    * a tool-call map `%{name: name, arguments: args}` (atom or string keys), or
    * a raw command / path string.

  Returns `{:blocked, reason}` when the input matches a hard-blocked pattern,
  or `:ok` otherwise. For tool-call maps, only shell and file-delete tools are
  inspected; every other tool short-circuits to `:ok`.
  """
  @spec blocked?(map() | String.t() | any()) :: result()
  def blocked?(input), do: input |> classify() |> drop_severity()

  @doc """
  Like `blocked?/1`, but keeps the severity class of the match.

  Returns `{:blocked, reason, :catastrophic | :confirm_required | :overridable}`
  or `:ok`. Only the permission boundary (`ToolExecutor.approve_tool_call/2`)
  should use this — it is the one caller that knows the session's permission
  mode and can therefore decide whether an `:overridable` match has been
  authorised, or turn a `:confirm_required` match into a prompt.
  """
  @spec classify(map() | String.t() | any()) :: classified()
  def classify(%{name: name} = call) do
    blocked_tool_call(name, call_arguments(call))
  end

  def classify(%{"name" => name} = call) do
    blocked_tool_call(name, call_arguments(call))
  end

  def classify(text) when is_binary(text) do
    check_command_classified(text)
  end

  def classify(_), do: :ok

  @doc "True when `severity` may be waived by overdrive/bypass."
  @spec overridable?(severity()) :: boolean()
  def overridable?(:overridable), do: true
  def overridable?(_), do: false

  defp drop_severity({:blocked, reason, _severity}), do: {:blocked, reason}
  defp drop_severity(:ok), do: :ok

  # ── tool-call dispatch ──────────────────────────────────────────────

  defp blocked_tool_call(name, args) when is_binary(name) do
    cond do
      name in @shell_tools ->
        check_command_classified(shell_text(args))

      name in @delete_tools ->
        check_path_classified(path_text(args))

      # Outbound MCP tools (mcp__<server>__<tool>) may be shell/desktop-command
      # servers running on the host. We can't know which one is a shell, so scan
      # their string arguments for the same hard-blocked patterns. The breaker
      # must apply to mcp_* tools even in :full/bypass tier.
      String.starts_with?(name, "mcp__") ->
        case check_command_classified(shell_text(args)) do
          {:blocked, _, _} = blocked -> blocked
          :ok -> check_path_classified(path_text(args))
        end

      true ->
        :ok
    end
  end

  defp blocked_tool_call(_name, _args), do: :ok

  # A shell tool's command is in "command"/"code"; fall back to any string arg.
  defp shell_text(args) when is_map(args) do
    val =
      Map.get(args, "command") || Map.get(args, "code") ||
        Map.get(args, :command) || Map.get(args, :code) ||
        first_string(args)

    if is_binary(val), do: val, else: ""
  end

  defp shell_text(text) when is_binary(text), do: text
  defp shell_text(_), do: ""

  defp path_text(args) when is_map(args) do
    val =
      Map.get(args, "path") || Map.get(args, "target") ||
        Map.get(args, :path) || Map.get(args, :target) ||
        first_string(args)

    if is_binary(val), do: val, else: ""
  end

  defp path_text(text) when is_binary(text), do: text
  defp path_text(_), do: ""

  defp first_string(args) do
    args |> Map.values() |> Enum.find(&is_binary/1)
  end

  defp call_arguments(%{arguments: args}), do: args
  defp call_arguments(%{"arguments" => args}), do: args
  defp call_arguments(_), do: %{}

  # ── the actual policy checks ────────────────────────────────────────

  @doc """
  Check a raw shell command string against every circuit-breaker pattern.
  Exposed for direct use by shell handlers / hooks.

  The patterns are applied to EVERY variant of the command (unquoted forms,
  wrapper payloads) — see `CommandVariants`. A match on any variant blocks.
  """
  @spec check_command(String.t()) :: result()
  def check_command(command), do: command |> check_command_classified() |> drop_severity()

  @doc """
  `check_command/1` keeping the severity class. See `classify/1`.
  """
  @spec check_command_classified(String.t()) :: classified()
  def check_command_classified(command) when is_binary(command) do
    variants = CommandVariants.variants(command)

    # A catastrophic match anywhere in the variant set outranks a
    # confirm-required or overridable one: `curl x | sh` next to `rm -rf /`
    # must report as catastrophic, or overdrive would waive the whole command
    # on the strength of the weaker match. Likewise a confirm-required match
    # outranks an overridable one — a command that both force-pushes to main
    # AND deletes an unresolvable target must still prompt, not silently run
    # under overdrive on the strength of the force-push half alone. Scan in
    # that priority order.
    find_match(variants, :catastrophic) || find_match(variants, :confirm_required) ||
      find_match(variants, :overridable) || :ok
  end

  def check_command_classified(_), do: :ok

  defp find_match(variants, severity) do
    Enum.find_value(variants, fn variant ->
      case check_variant(variant) do
        {:blocked, _, ^severity} = blocked -> blocked
        _ -> nil
      end
    end)
  end

  @doc """
  The unrecoverable **filesystem/system destruction** subset of the breaker:
  `rm -rf` at a broad root, fork bombs, `dd` to a block device, `mkfs`.

  This is the single source of truth for that class. `shell_execute`'s
  hard-deny tier delegates here rather than keeping a second copy of the same
  patterns — two lists that must stay in sync is precisely how the quoting hole
  survived in one of them.
  """
  @spec catastrophic_destruction?(String.t()) :: boolean()
  def catastrophic_destruction?(command) when is_binary(command) do
    CommandVariants.any?(command, fn variant ->
      rm_rf_broad_root?(variant) or
        fork_bomb?(variant) or
        Regex.match?(@dd_block_device, variant) or
        Regex.match?(@mkfs, variant)
    end)
  end

  def catastrophic_destruction?(_), do: false

  # A single variant against every pattern.
  #
  # ORDER IS LOAD-BEARING: every `:catastrophic` clause precedes every
  # `:confirm_required` one, which in turn precedes every `:overridable` one,
  # so a command that matches more than one class reports as the STRICTER
  # class and can never be waived on the strength of the weaker match
  # (`git push --force origin main && mkfs.ext4 /dev/sda1`).
  defp check_variant(command) when is_binary(command) do
    cond do
      # ── :catastrophic — unrecoverable, blocked in EVERY mode ───────────
      rm_rf_broad_root?(command) ->
        {:blocked, "recursive force-delete of a root/home path (rm -rf) is never permitted",
         :catastrophic}

      fork_bomb?(command) ->
        {:blocked, "fork bomb pattern is never permitted", :catastrophic}

      Regex.match?(@dd_block_device, command) ->
        {:blocked, "dd writing directly to a block device is never permitted", :catastrophic}

      Regex.match?(@mkfs, command) ->
        {:blocked, "creating a filesystem (mkfs) on a device is never permitted", :catastrophic}

      Regex.match?(@drop_database, command) ->
        {:blocked, "DROP DATABASE/SCHEMA is never permitted", :catastrophic}

      Regex.match?(@drop_truncate_prod, command) ->
        {:blocked, "DROP TABLE/TRUNCATE on a production database is never permitted",
         :catastrophic}

      # ── :confirm_required — cannot be proven safe OR unsafe; always ask ─
      #
      # A recursive delete whose target is a command substitution, backtick,
      # brace expansion, a bare/positional variable, or a glob at/near a
      # filesystem root. Unlike every other clause here this is not a verdict
      # about the command — it is an admission that the breaker cannot render
      # one statically, so the decision goes to the operator instead of being
      # guessed in either direction. See the moduledoc's `## The three classes`.
      rm_rf_unresolvable_target?(command) ->
        {:blocked,
         "recursive delete whose target cannot be resolved without running the shell " <>
           "(a command substitution, variable expansion, or a glob at/near a filesystem root)",
         :confirm_required}

      # Same reasoning, via `find`'s own destructive primaries (`-delete`,
      # `-exec rm`) instead of `rm -rf` directly.
      find_delete_unresolvable_target?(command) ->
        {:blocked,
         "find with a destructive primary (-delete / -exec rm) whose target cannot be " <>
           "resolved without running the shell", :confirm_required}

      # ── :overridable — recoverable, waived only under overdrive/bypass ─
      #
      # Force-push to a protected branch: destructive to *history*, not to the
      # machine, and recoverable from the remote's reflog. It is also a normal
      # operation in a scratch container or a solo repo, which is why refusing
      # it under an explicit full-auto mode is a dead end for the operator.
      force_push_protected?(command) ->
        {:blocked, "force-push to a protected branch is never permitted", :overridable}

      # curl|sh: a supply-chain hazard (unreviewed remote code), not
      # destruction — and the documented install path for a large amount of
      # real software. Under overdrive the operator has already accepted
      # unattended execution of remote instructions.
      Regex.match?(@pipe_to_shell, command) ->
        {:blocked, "piping downloaded content directly into a shell (curl|sh) is never permitted",
         :overridable}

      true ->
        :ok
    end
  end

  # A file-delete tool targeting a broad root path is a hard stop.
  @spec check_path(String.t()) :: result()
  def check_path(path), do: path |> check_path_classified() |> drop_severity()

  @doc "`check_path/1` keeping the severity class (always `:catastrophic`)."
  @spec check_path_classified(String.t()) :: classified()
  def check_path_classified(path) when is_binary(path) do
    # A path argument is not shell-processed, but it may still arrive quoted
    # from a model that wrote it as it would in a shell. Check both forms.
    unquoted = CommandVariants.shell_unquote(path)

    if unquoted != path do
      case check_one_path(unquoted) do
        {:blocked, _, _} = blocked -> blocked
        :ok -> check_one_path(path)
      end
    else
      check_one_path(path)
    end
  end

  def check_path_classified(_), do: :ok

  # Deleting a root/home path outright is unrecoverable — :catastrophic, and
  # therefore not waivable by overdrive.
  defp check_one_path(path) do
    expanded = safe_expand(path)

    broad_roots =
      [
        "/",
        safe_expand("~"),
        System.get_env("HOME") || "/home",
        "/etc",
        "/usr",
        "/bin",
        "/boot",
        "/var",
        "/lib",
        "/System",
        "/Library"
      ]
      |> Enum.reject(&is_nil/1)

    trimmed = String.trim(path)

    cond do
      trimmed in ["/", "~", "~/", "/*", "*", ".", "..", "$HOME"] ->
        {:blocked, "deleting a root/home path is never permitted", :catastrophic}

      expanded in broad_roots ->
        {:blocked, "deleting a root/home path is never permitted", :catastrophic}

      true ->
        :ok
    end
  end

  # A shell function whose body BOTH pipes and backgrounds — `:(){ :|:& };:`.
  #
  # `@fork_bomb` captures each function body; the `|`/`&` test lives here
  # because expressing it in the regex is what made the pattern quadratic (see
  # the note on `@fork_bomb`). `scan/3` is used rather than `run/3` so that a
  # harmless definition ahead of the bomb — `f(){ echo hi }; g(){ g|g& };g` —
  # cannot hide it.
  defp fork_bomb?(command) when is_binary(command) do
    @fork_bomb
    |> Regex.scan(command, capture: :all_but_first)
    |> Enum.any?(fn [body] ->
      String.contains?(body, "|") and String.contains?(body, "&")
    end)
  end

  defp fork_bomb?(_), do: false

  # rm + recursive + force + a broad-root target — all present, order-insensitive.
  defp rm_rf_broad_root?(command) do
    Regex.match?(@rm_invocation, command) and
      Regex.match?(@rm_recursive_flag, command) and
      Regex.match?(@rm_force_flag, command) and
      Regex.match?(@broad_root_target, command)
  end

  # rm, RECURSIVE (force NOT required — `rm -r` alone still deletes everything
  # it can reach non-interactively, and it is `-r` that makes the blast radius
  # a whole tree instead of one file), targeting something the breaker cannot
  # statically resolve (command substitution/backtick/brace-expansion/bare or
  # positional variable, or a glob at/near a filesystem root). See
  # `:confirm_required` in the moduledoc.
  defp rm_rf_unresolvable_target?(command) do
    Regex.match?(@rm_invocation, command) and
      Regex.match?(@rm_recursive_flag, command) and
      (Regex.match?(@rm_dynamic_target, command) or Regex.match?(@rm_near_root_glob, command))
  end

  # find with a destructive primary (-delete / -exec rm) and a dynamic
  # expansion anywhere on the line — independent, order-insensitive, exactly
  # like the rm check above.
  defp find_delete_unresolvable_target?(command) do
    Regex.match?(@find_destructive_primary, command) and
      Regex.match?(@dynamic_expansion, command)
  end

  defp force_push_protected?(command) do
    Regex.match?(@force_push_flag, command) and mentions_protected_branch?(command)
  end

  # Treat a force push as protected-branch-targeting when a protected branch
  # name appears in the command, OR when no explicit branch is given (a bare
  # `git push --force` pushes the current branch — fail safe by blocking).
  defp mentions_protected_branch?(command) do
    lower = String.downcase(command)

    Enum.any?(@protected_branches, fn b ->
      Regex.match?(~r/(?:^|[\s\/:+])#{Regex.escape(b)}(?:$|[\s:@~^])/, lower)
    end) or bare_force_push?(lower)
  end

  # `git push --force` / `git push -f` with no remote+refspec after it → the
  # current branch, which we cannot prove is unprotected. Block conservatively.
  defp bare_force_push?(lower) do
    Regex.match?(~r/\bgit\s+push\s+(?:--force(?:-with-lease)?|-\w*f\w*)\s*$/, lower)
  end

  defp safe_expand(path) do
    Path.expand(path)
  rescue
    _ -> path
  end

  @doc "The shell tool names inspected by the circuit-breaker."
  @spec shell_tools() :: [String.t()]
  def shell_tools, do: @shell_tools

  @doc "The file-delete tool names inspected by the circuit-breaker."
  @spec delete_tools() :: [String.t()]
  def delete_tools, do: @delete_tools
end
