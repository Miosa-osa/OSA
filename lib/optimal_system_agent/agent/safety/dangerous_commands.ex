defmodule OptimalSystemAgent.Agent.Safety.DangerousCommands do
  @moduledoc """
  POLICY DATA: the circuit-breaker blocklist, in two severity classes.

  This module is the last line of defence. Unlike the auto-mode `Rules`
  (which are risk-tiered — `:caution`/`:dangerous` verdicts that the Guardian
  may *allow*, block, or pause depending on the session's permission tier), the
  patterns here are blocked **in every permission tier**, with exactly one
  documented exception described below. There is no counter, no pause-after-N,
  no allowlist, no config toggle.

  ## The two classes, and why there are two

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
  and gets the strict, mode-independent verdict (both classes blocked), because
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

    * `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`, `rm -rf /*`, `rm -rf .` and other
      recursive-force deletes rooted at a broad root.
    * Fork bombs (`:(){ :|:& };:` and obfuscated variants).
    * `dd` writing to a block device (`of=/dev/sda`, `/dev/nvme…`, `/dev/disk…`).
    * `mkfs` / filesystem creation on any device.
    * `DROP DATABASE` / `DROP SCHEMA`.
    * `DROP TABLE` / `TRUNCATE` targeting a production database/table.
    * `file_delete` on a root/home path.

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
    * `:overridable` — bounded, recoverable risk. Blocked in every mode except
      `:overdrive`/`:bypass`, where the operator has taken explicit
      responsibility for unattended execution.
  """
  @type severity :: :catastrophic | :overridable
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

  # A broad root target: /, /*, ~, ~/, ~/*, $HOME (opt /), ., .., *, or a bare
  # top-level system directory (/etc, /usr, /home, …). Must be delimited so it
  # is the whole argument, not a prefix of a deeper, scoped path.
  @broad_root_target ~r/(?:^|\s)(?:\/|\/\*|~|~\/|~\/\*|\$\{?HOME\}?\/?|\.|\.\.|\*|\/(?:etc|usr|bin|sbin|boot|dev|lib|lib64|proc|root|run|sys|var|opt|home|Users|System|Library))(?=[\s;&|)]|$)/

  # ── force push to protected branch ──────────────────────────────────
  @force_push_flag ~r/\bgit\s+push\b[^\n]*(?:--force\b(?!-with-lease)|--force-with-lease\b|(?:^|\s)-\w*f\w*\b|\s\+[\w\/.-]+)/i

  # ── fork bomb ───────────────────────────────────────────────────────
  # Classic `:(){ :|:& };:` and single-char-function variants like
  # `b(){ b|b& };b`. Match a function def whose body pipes itself and
  # backgrounds, then is invoked.
  @fork_bomb ~r/(\S+)\s*\(\s*\)\s*\{[^}]*\|[^}]*&[^}]*\}\s*;?\s*\1?/

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

  Returns `{:blocked, reason, :catastrophic | :overridable}` or `:ok`. Only the
  permission boundary (`ToolExecutor.approve_tool_call/2`) should use this — it
  is the one caller that knows the session's permission mode and can therefore
  decide whether an `:overridable` match has been authorised.
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

    # A catastrophic match anywhere in the variant set outranks an overridable
    # one: `curl x | sh` next to `rm -rf /` must report as catastrophic, or
    # overdrive would waive the whole command on the strength of the weaker
    # match. Scan for catastrophic first, then for overridable.
    find_match(variants, :catastrophic) || find_match(variants, :overridable) || :ok
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
        Regex.match?(@fork_bomb, variant) or
        Regex.match?(@dd_block_device, variant) or
        Regex.match?(@mkfs, variant)
    end)
  end

  def catastrophic_destruction?(_), do: false

  # A single variant against every pattern.
  #
  # ORDER IS LOAD-BEARING: every `:catastrophic` clause precedes every
  # `:overridable` one, so a command that matches both classes reports as
  # catastrophic and can never be waived on the strength of the weaker match
  # (`git push --force origin main && mkfs.ext4 /dev/sda1`).
  defp check_variant(command) when is_binary(command) do
    cond do
      # ── :catastrophic — unrecoverable, blocked in EVERY mode ───────────
      rm_rf_broad_root?(command) ->
        {:blocked, "recursive force-delete of a root/home path (rm -rf) is never permitted",
         :catastrophic}

      Regex.match?(@fork_bomb, command) ->
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

  # rm + recursive + force + a broad-root target — all present, order-insensitive.
  defp rm_rf_broad_root?(command) do
    Regex.match?(@rm_invocation, command) and
      Regex.match?(@rm_recursive_flag, command) and
      Regex.match?(@rm_force_flag, command) and
      Regex.match?(@broad_root_target, command)
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
