defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants do
  @moduledoc """
  Exported constants for `shell_execute`. Mirrors the pattern established by
  `FileRead.Constants` — other tools' prompts can reference `tool_name/0` so
  a rename propagates automatically.
  """

  @tool_name "shell_execute"
  def tool_name, do: @tool_name

  @max_output_bytes 102_400
  def max_output_bytes, do: @max_output_bytes

  # Hard wall-clock cap for a single foreground command. Kept intentionally
  # conservative (2 min) so a hung / input-blocked command can never run for
  # minutes silently — the run_command timeout path kills the OS process when
  # this elapses. Override per-call via OSA_SHELL_TIMEOUT_MS.
  @default_timeout_ms 120_000
  def default_timeout_ms, do: @default_timeout_ms

  # Blocked command names — matched at word boundaries across pipes,
  # semicolons, && and ||.
  @blocked_commands ~w(
    rm sudo dd mkfs fdisk chmod chown kill killall pkill
    reboot shutdown halt poweroff mount umount
    iptables systemctl passwd useradd userdel
    nc ncat
    env printenv export set declare compgen
  )
  def blocked_commands, do: @blocked_commands

  # Download commands with output flags — matched as patterns.
  @download_patterns [
    ~r/\bcurl\b.*(-o|--output)\b/,
    ~r/\bwget\b.*-O\b/
  ]
  def download_patterns, do: @download_patterns

  # Environment variables that are universally safe to expand.
  # These hold read-only runtime context (paths/identity) and carry no
  # secret material; blocking them prevents legitimate commands like
  # `echo $HOME` or `ls $PATH` from working.
  @safe_env_vars ~w(HOME PATH SHELL USER LANG TMPDIR TERM EDITOR)
  def safe_env_vars, do: @safe_env_vars

  # Shell injection patterns.
  #
  # NOTE on bare $VAR handling: we block most $VAR expansions to prevent
  # exfiltration (e.g. `echo $AWS_SECRET_KEY`) but we allow the small
  # allowlist of @safe_env_vars above (HOME, PATH, SHELL, USER, LANG,
  # TMPDIR, TERM, EDITOR).  The regex therefore uses a negative lookahead
  # to skip those safe names before the generic $IDENTIFIER block fires.
  @injection_patterns [
    # backtick substitution
    ~r/`/,
    # $() command substitution
    ~r/\$\(/,
    # ${} variable expansion
    ~r/\$\{/,
    # bare $VAR expansion — blocked EXCEPT for the safe envvar allowlist.
    # The lookahead skips e.g. $HOME, $PATH, $SHELL … so they pass through.
    ~r/\$(?!(?:HOME|PATH|SHELL|USER|LANG|TMPDIR|TERM|EDITOR)(?:\s|$|[^A-Za-z0-9_]))[A-Za-z_]\w*/,
    # redirect to /etc/
    ~r/>\s*\/etc\//,
    # redirect to /usr/
    ~r/>\s*\/usr\//
  ]
  def injection_patterns, do: @injection_patterns

  # Path traversal / sensitive file patterns.
  @path_patterns [
    # ../ traversal
    ~r/\.\.\//,
    # /etc/ access
    ~r/\/etc\//,
    # .ssh/ access
    ~r/\.ssh\//,
    # .env file access (including .env.backup, .environment, etc.)
    ~r/\.env/
  ]
  def path_patterns, do: @path_patterns

  # /proc environ leak patterns — catches attempts to read env vars via procfs.
  @env_leak_patterns [
    ~r|/proc/\w+/environ|,
    ~r|/proc/self/environ|
  ]
  def env_leak_patterns, do: @env_leak_patterns

  # cd restriction — only allow cd within ~/.osa/
  @cd_pattern ~r/\bcd\s+(?!~?\/?\.osa)/
  def cd_pattern, do: @cd_pattern
end
