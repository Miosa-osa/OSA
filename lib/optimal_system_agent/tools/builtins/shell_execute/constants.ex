defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants do
  @moduledoc """
  Exported constants for `shell_execute`. Mirrors the pattern established by
  `FileRead.Constants` — other tools' prompts can reference `tool_name/0` so
  a rename propagates automatically.

  ## Security model (Claude-Code aligned)

  The agent runs locally AS the operator, who WANTS it to do real work — build,
  edit, run multi-step tasks. So we do NOT cage it. Instead there are three
  tiers, matching how Claude Code treats shell:

    * **catastrophic** (`catastrophic_patterns/0`) — unrecoverable disk/system
      destruction (wipe `/` or `$HOME`, `mkfs`, `dd` to a device, fork bomb,
      power off). These are HARD-DENIED, never even offered.
    * **risky** (`ask_commands/0`, `ask_patterns/0`) — powerful but legitimate
      (`rm`, `sudo`, `chmod`, `kill`, `systemctl`, pipe-to-shell). These route
      to the inline permission PROMPT so the operator approves in-context.
    * **safe** — everything else (including command substitution `$(...)`,
      backticks, `$VAR`, reading `/etc/*`, relative `../` paths, `cd` anywhere,
      `env`/`export`). Allowed outright.

  The old blocklist hard-denied command substitution, `/etc` reads, `.env`
  reads, and caged `cd` to `~/.osa/` — which broke ordinary development and made
  the agent untrustworthy. That paranoia is gone; the permission prompt is the
  gate now.
  """

  @tool_name "shell_execute"
  def tool_name, do: @tool_name

  @max_output_bytes 102_400
  def max_output_bytes, do: @max_output_bytes

  # How long the AGENT waits inline for a foreground command — a YIELD window,
  # not a kill deadline.
  #
  # This value only decides when a still-running command is moved to the
  # background (see `auto_detach_on_timeout/5`); the process itself keeps running
  # and its completion is injected back into the loop. Because expiry is no longer
  # destructive, a SHORT window is correct and desirable: the agent stops blocking
  # on slow work and can carry on, exactly as Codex does (its `shell` default is
  # 10 s, after which the process becomes a background session the model polls).
  #
  # It was briefly raised to 4 h while expiry still meant SIGKILL — the right fix
  # for "long work gets destroyed", but the wrong shape: it made the agent sit and
  # block for hours instead. Bound the wait, not the work.
  #
  # 2 minutes. Override with OSA_SHELL_TIMEOUT_MS or `[shell].timeout_ms`.
  @default_timeout_ms 120_000
  def default_timeout_ms, do: @default_timeout_ms

  # ── Tier 1: CATASTROPHIC — always hard-denied (unrecoverable) ──────────
  #
  # Targeted, high-specificity patterns. We deliberately keep this SMALL: only
  # actions that destroy the disk/home/system with no recovery. Anything that is
  # merely powerful (a scoped `rm -rf ./build`) is NOT here — it goes to `:ask`.
  # NOTE: all sigils use the `/` delimiter with internal `/` escaped as `\/`.
  # (An earlier `~r|…|` form broke compilation — the `|` delimiter collided with
  # the `|` alternations inside the patterns.)
  @catastrophic_patterns [
    # rm -rf targeting a filesystem/home ROOT (not a scoped subdir):
    #   rm -rf /        rm -rf /*        rm -rf ~        rm -rf $HOME
    #   rm --recursive --force /   (long flags, any order)
    ~r/\brm\s+(?:-[a-zA-Z]*\s+|--[a-z]+\s+)*(?:\/|~|\$HOME|\/\*|~\/\*|\$HOME\/\*)\s*$/,
    ~r/\brm\s+(?:-[a-zA-Z]*\s+|--[a-z]+\s+)*(?:\/|~|\$HOME)\/?\*/,
    # Classic fork bomb :(){ :|:& };:
    ~r/:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/,
    # Filesystem formatting / partitioning
    ~r/\bmkfs(\.\w+)?\b/,
    ~r/\bfdisk\b/,
    ~r/\bmkswap\b/,
    # dd writing directly to a block device
    ~r/\bdd\b[^|;&]*\bof=\/dev\//,
    # Redirect into a raw disk device
    ~r/>\s*\/dev\/(sd|nvme|hd|vd|mmcblk)/,
    # Recursive chmod/chown on a filesystem root
    ~r/\bch(mod|own)\s+(-[a-zA-Z]*R[a-zA-Z]*\s+|--recursive\s+)\S*\s+\/\s*$/
  ]
  def catastrophic_patterns, do: @catastrophic_patterns

  # ── Tier 2: RISKY — route to the inline permission PROMPT (:ask) ───────
  #
  # Legitimate but powerful. The operator approves in-context. These are the
  # first word (command name) of any pipe/;/&&/|| segment.
  @ask_commands ~w(
    rm sudo dd chmod chown kill killall pkill
    mount umount iptables nftables
    passwd useradd userdel usermod groupadd
    systemctl service launchctl
    nc ncat socat
    shutdown reboot halt poweroff
  )
  def ask_commands, do: @ask_commands

  # Risky PATTERNS that also route to :ask (pipe-to-shell is the big one — the
  # canonical `curl … | sh` remote-code path; legitimate for installs but must
  # be seen). Downloads-with-output are fine to run once approved.
  @ask_patterns [
    # pipe into a shell interpreter: `… | sh`, `… | bash`, `… | zsh`
    ~r/\|\s*(sudo\s+)?(sh|bash|zsh|fish|dash)\b/,
    # curl/wget piped or fetched for execution
    ~r/\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b/,
    # writing/appending into a system config dir via redirect
    ~r/>>?\s*\/(etc|boot|sys|usr\/bin|usr\/sbin|bin|sbin)\//,
    # git hard reset / clean / force-push (destructive to work)
    ~r/\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*f|push\s+.*--force|push\s+.*-f\b)/
  ]
  def ask_patterns, do: @ask_patterns

  # Environment variables that are universally safe to expand — retained for any
  # callers that still reference the allowlist. (Command substitution and $VAR
  # are no longer blocked, so this is now informational only.)
  @safe_env_vars ~w(HOME PATH SHELL USER LANG TMPDIR TERM EDITOR)
  def safe_env_vars, do: @safe_env_vars

  # ── Config overlay accessors (~/.osa/config.toml) ──────────────────────
  #
  # The lists above are the DEFAULTS. An operator can extend/override them via
  # the `[permissions]` section of `~/.osa/config.toml` (see
  # `OptimalSystemAgent.ConfigFile`). These `effective_*` accessors merge the
  # config on top of the defaults and are what the handler consults at runtime.
  # The raw `@defaults` accessors above are preserved unchanged for callers /
  # tests that want the built-in baseline.

  alias OptimalSystemAgent.ConfigFile

  @doc "Defaults ++ operator `[permissions].ask_commands` (risky :ask tier)."
  def effective_ask_commands do
    (@ask_commands ++ safe(fn -> ConfigFile.permission_ask_commands() end, []))
    |> Enum.uniq()
  end

  @doc "Defaults ++ operator `[permissions].ask_patterns` (risky :ask tier)."
  def effective_ask_patterns do
    @ask_patterns ++ safe(fn -> ConfigFile.permission_ask_patterns() end, [])
  end

  @doc """
  Defaults ++ operator `[permissions].catastrophic_patterns` ++ patterns from
  `[permissions].deny` (hard-deny tier).
  """
  def effective_catastrophic_patterns do
    @catastrophic_patterns ++
      safe(fn -> ConfigFile.permission_catastrophic_patterns() end, []) ++
      safe(fn -> ConfigFile.permission_deny_patterns() end, [])
  end

  @doc "Command heads the operator hard-denies via `[permissions].deny`."
  def deny_commands, do: safe(fn -> ConfigFile.permission_deny_commands() end, [])

  @doc "Command heads the operator always allows via `[permissions].allow`."
  def allow_commands, do: safe(fn -> ConfigFile.permission_allow_commands() end, [])

  @doc "Regex patterns the operator always allows via `[permissions].allow`."
  def allow_patterns, do: safe(fn -> ConfigFile.permission_allow_patterns() end, [])

  @doc "Operator shell timeout override (`[shell].timeout_ms`) or the default."
  def effective_timeout_ms do
    safe(fn -> ConfigFile.shell_timeout_ms() end, nil) || @default_timeout_ms
  end

  # Never let a malformed config crash the permission gate — fall back to the
  # built-in defaults if ConfigFile raises for any reason.
  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    _, _ -> fallback
  end
end
