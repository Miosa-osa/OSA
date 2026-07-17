defmodule OptimalSystemAgent.Agent.Safety.DangerousCommands do
  @moduledoc """
  POLICY DATA: the HARD, non-bypassable circuit-breaker blocklist.

  This module is the last line of defence. Unlike the auto-mode `Rules`
  (which are risk-tiered — `:caution`/`:dangerous` verdicts that the Guardian
  may *allow*, block, or pause depending on the session's permission tier), the
  patterns here are **ALWAYS blocked, in every permission tier** — including
  `:full` / bypass. There is no counter, no pause-after-N, no allowlist, no
  config toggle: a match is a hard stop.

  Separation of concerns:

    * `Rules` / `Classifier` / `Guardian` — the *allowable* risk-tiered
      auto-mode safety policy. Tier-dependent enforcement.
    * `DangerousCommands` (this module) — the *never, under any circumstances*
      subset. Tier-independent enforcement, wired as the FIRST clause of the
      tool-execution boundary so it cannot be bypassed.

  It is **pure**: no I/O, no state, no config reads. `blocked?/1` returns
  `{:blocked, reason}` or `:ok`.

  ## What is always blocked

    * `rm -rf /`, `rm -rf ~`, `rm -rf $HOME`, `rm -rf /*`, `rm -rf .` and other
      recursive-force deletes rooted at a broad root.
    * `git push --force` / `-f` / `+ref` to a protected branch
      (main, master, production, release, develop, staging, prod).
    * Fork bombs (`:(){ :|:& };:` and obfuscated variants).
    * `dd` writing to a block device (`of=/dev/sda`, `/dev/nvme…`, `/dev/disk…`).
    * `mkfs` / filesystem creation on any device.
    * `DROP DATABASE` / `TRUNCATE` targeting a production database/table.
    * Pipe-to-shell of downloaded content (`curl … | sh`, `wget … | bash`,
      `curl … | sudo sh`).
  """

  @type reason :: String.t()
  @type result :: {:blocked, reason()} | :ok

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
  def blocked?(%{name: name} = call) do
    blocked_tool_call(name, call_arguments(call))
  end

  def blocked?(%{"name" => name} = call) do
    blocked_tool_call(name, call_arguments(call))
  end

  def blocked?(text) when is_binary(text) do
    check_command(text)
  end

  def blocked?(_), do: :ok

  # ── tool-call dispatch ──────────────────────────────────────────────

  defp blocked_tool_call(name, args) when is_binary(name) do
    cond do
      name in @shell_tools ->
        check_command(shell_text(args))

      name in @delete_tools ->
        check_path(path_text(args))

      # Outbound MCP tools (mcp__<server>__<tool>) may be shell/desktop-command
      # servers running on the host. We can't know which one is a shell, so scan
      # their string arguments for the same hard-blocked patterns. The breaker
      # must apply to mcp_* tools even in :full/bypass tier.
      String.starts_with?(name, "mcp__") ->
        case check_command(shell_text(args)) do
          {:blocked, _} = blocked -> blocked
          :ok -> check_path(path_text(args))
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
  """
  @spec check_command(String.t()) :: result()
  def check_command(command) when is_binary(command) do
    cond do
      rm_rf_broad_root?(command) ->
        {:blocked, "recursive force-delete of a root/home path (rm -rf) is never permitted"}

      force_push_protected?(command) ->
        {:blocked, "force-push to a protected branch is never permitted"}

      Regex.match?(@fork_bomb, command) ->
        {:blocked, "fork bomb pattern is never permitted"}

      Regex.match?(@dd_block_device, command) ->
        {:blocked, "dd writing directly to a block device is never permitted"}

      Regex.match?(@mkfs, command) ->
        {:blocked, "creating a filesystem (mkfs) on a device is never permitted"}

      Regex.match?(@drop_database, command) ->
        {:blocked, "DROP DATABASE/SCHEMA is never permitted"}

      Regex.match?(@drop_truncate_prod, command) ->
        {:blocked, "DROP TABLE/TRUNCATE on a production database is never permitted"}

      Regex.match?(@pipe_to_shell, command) ->
        {:blocked, "piping downloaded content directly into a shell (curl|sh) is never permitted"}

      true ->
        :ok
    end
  end

  def check_command(_), do: :ok

  # A file-delete tool targeting a broad root path is a hard stop.
  @spec check_path(String.t()) :: result()
  def check_path(path) when is_binary(path) do
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
        {:blocked, "deleting a root/home path is never permitted"}

      expanded in broad_roots ->
        {:blocked, "deleting a root/home path is never permitted"}

      true ->
        :ok
    end
  end

  def check_path(_), do: :ok

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
