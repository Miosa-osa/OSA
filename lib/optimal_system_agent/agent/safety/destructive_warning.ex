defmodule OptimalSystemAgent.Agent.Safety.DestructiveWarning do
  @moduledoc """
  Informational destructive-command detection (CC `destructiveCommandWarning.ts`
  port). Returns a one-line warning for the permission dialog — purely
  informational, never affects permission logic or auto-approval. The hard,
  non-bypassable subset lives in `DangerousCommands`; this module covers the
  *allowable-but-risky* commands worth flagging to the user before approval.
  """

  @patterns [
    # Git — data loss / hard to reverse
    {~r/\bgit\s+reset\s+--hard\b/, "Note: may discard uncommitted changes"},
    {~r/\bgit\s+push\b[^;&|\n]*[ \t](--force|--force-with-lease|-f)\b/,
     "Note: may overwrite remote history"},
    {~r/\bgit\s+clean\b(?![^;&|\n]*(?:-[a-zA-Z]*n|--dry-run))[^;&|\n]*-[a-zA-Z]*f/,
     "Note: may permanently delete untracked files"},
    {~r/\bgit\s+checkout\s+(--\s+)?\.[ \t]*($|[;&|\n])/,
     "Note: may discard all working tree changes"},
    {~r/\bgit\s+restore\s+(--\s+)?\.[ \t]*($|[;&|\n])/,
     "Note: may discard all working tree changes"},
    {~r/\bgit\s+stash[ \t]+(drop|clear)\b/, "Note: may permanently remove stashed changes"},
    {~r/\bgit\s+branch\s+(-D[ \t]|--delete\s+--force|--force\s+--delete)\b/,
     "Note: may force-delete a branch"},
    # Git — safety bypass
    {~r/\bgit\s+(commit|push|merge)\b[^;&|\n]*--no-verify\b/, "Note: may skip safety hooks"},
    {~r/\bgit\s+commit\b[^;&|\n]*--amend\b/, "Note: may rewrite the last commit"},
    # File deletion
    {~r/(^|[;&|\n]\s*)rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f|(^|[;&|\n]\s*)rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR]/,
     "Note: may recursively force-remove files"},
    {~r/(^|[;&|\n]\s*)rm\s+-[a-zA-Z]*[rR]/, "Note: may recursively remove files"},
    {~r/(^|[;&|\n]\s*)rm\s+-[a-zA-Z]*f/, "Note: may force-remove files"},
    # Database
    {~r/\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b/i,
     "Note: may drop or truncate database objects"},
    {~r/\bDELETE\s+FROM\s+\w+[ \t]*(;|"|'|\n|$)/i,
     "Note: may delete all rows from a database table"},
    # Infrastructure
    {~r/\bkubectl\s+delete\b/, "Note: may delete Kubernetes resources"},
    {~r/\bterraform\s+destroy\b/, "Note: may destroy Terraform infrastructure"}
  ]

  @doc "First matching destructive warning for a shell command, or nil."
  @spec warning_for(String.t() | any()) :: String.t() | nil
  def warning_for(command) when is_binary(command) do
    Enum.find_value(@patterns, fn {re, warning} ->
      if Regex.match?(re, command), do: warning
    end)
  end

  def warning_for(_), do: nil
end
