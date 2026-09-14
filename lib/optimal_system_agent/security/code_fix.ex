defmodule OptimalSystemAgent.Security.CodeFix do
  @moduledoc """
  Code fix as part of vulnerability reporting (Tier 3 #15).

  Adapted from Strix's fix_before/fix_after pattern. A vulnerability report is
  far more actionable when it includes the concrete remediation as a code
  diff, not just prose ("you should sanitize input"). This module records a
  fix_before/fix_after pair for a finding, renders it as a unified diff, and
  attaches it to the finding's report entry.

  ## What it stores

  For each finding key, a fix record holds:
  - `finding_key` — the StructuredNotes key of the vulnerability note
  - `file_path` — the file the fix applies to
  - `fix_before` — the vulnerable code (string)
  - `fix_after` — the remediated code (string)
  - `language` — for syntax highlighting hints (optional)
  - `explanation` — why this fix addresses the root cause (string)

  ## Rendering

  `render_diff/1` produces a unified-diff-style block. `render_inline/1`
  produces a prompt-injectable block with the before/after and explanation.

  ## Persistence

  Fix records are stored per-session in an ETS-backed GenServer
  (`Security.CodeFixStore`) so they survive across turns and can be included
  in the final report.

  ## Usage

      CodeFix.record(session_id, %{
        finding_key: "vuln_sqli",
        file_path: "src/api/users.py",
        fix_before: "query = f\"SELECT * FROM users WHERE id={id}\"",
        fix_after: "query = \"SELECT * FROM users WHERE id=?\"",
        language: "python",
        explanation: "Parameterized query prevents SQL injection."
      })

      {:ok, fixes} = CodeFix.list(session_id)
      diff = CodeFix.render_diff(hd(fixes))
  """

  require Logger

  @type fix :: %{
          finding_key: String.t(),
          file_path: String.t(),
          fix_before: String.t(),
          fix_after: String.t(),
          language: String.t() | nil,
          explanation: String.t(),
          recorded_at: DateTime.t()
        }

  # ── Session state (delegates to CodeFixStore) ──────────────────────────

  @doc "Record a code fix for a finding."
  @spec record(String.t(), map()) :: {:ok, fix()} | {:error, String.t()}
  def record(session_id, data) when is_binary(session_id) and is_map(data) do
    with {:ok, _} <- OptimalSystemAgent.Security.CodeFixStore.ensure_started(session_id) do
      case validate_fix(data) do
        :ok ->
          fix = build_fix(data)
          OptimalSystemAgent.Security.CodeFixStore.put(session_id, fix)
          {:ok, fix}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "Get the fix for a specific finding key."
  @spec get(String.t(), String.t()) :: {:ok, fix()} | :not_found
  def get(session_id, finding_key)
      when is_binary(session_id) and is_binary(finding_key) do
    with {:ok, _} <- OptimalSystemAgent.Security.CodeFixStore.ensure_started(session_id) do
      OptimalSystemAgent.Security.CodeFixStore.get(session_id, finding_key)
    end
  end

  @doc "List all recorded fixes for a session."
  @spec list(String.t()) :: {:ok, [fix()]}
  def list(session_id) when is_binary(session_id) do
    with {:ok, _} <- OptimalSystemAgent.Security.CodeFixStore.ensure_started(session_id) do
      {:ok, OptimalSystemAgent.Security.CodeFixStore.list(session_id)}
    end
  end

  @doc "Delete a fix for a finding."
  @spec delete(String.t(), String.t()) :: :ok | :not_found
  def delete(session_id, finding_key)
      when is_binary(session_id) and is_binary(finding_key) do
    with {:ok, _} <- OptimalSystemAgent.Security.CodeFixStore.ensure_started(session_id) do
      OptimalSystemAgent.Security.CodeFixStore.delete(session_id, finding_key)
    end
  end

  # ── Rendering ──────────────────────────────────────────────────────────

  @doc "Render a fix as a unified-diff-style block."
  @spec render_diff(fix()) :: String.t()
  def render_diff(%{} = fix) do
    before_lines = String.split(fix.fix_before || "", "\n")
    after_lines = String.split(fix.fix_after || "", "\n")

    diff_lines = ["--- #{fix.file_path} (before)", "+++ #{fix.file_path} (after)"]

    diff_lines =
      diff_lines ++
        Enum.map(before_lines, fn line -> "-#{line}" end) ++
        Enum.map(after_lines, fn line -> "+#{line}" end)

    body = Enum.join(diff_lines, "\n")

    """
    <code_fix finding="#{fix.finding_key}" file="#{fix.file_path}">
    #{body}

    Explanation: #{fix.explanation}
    </code_fix>
    """
  end

  @doc "Render a fix as an inline before/after block (no diff markers)."
  @spec render_inline(fix()) :: String.t()
  def render_inline(%{} = fix) do
    lang = fix.language || ""

    """
    <code_fix finding="#{fix.finding_key}" file="#{fix.file_path}">
    Before (#{lang}):
    ```
    #{fix.fix_before}
    ```

    After (#{lang}):
    ```
    #{fix.fix_after}
    ```

    Explanation: #{fix.explanation}
    </code_fix>
    """
  end

  @doc "Render all fixes for a session as a single report section."
  @spec render_report(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def render_report(session_id) when is_binary(session_id) do
    case list(session_id) do
      {:ok, []} ->
        {:ok, "<code_fixes>\nNo code fixes recorded.\n</code_fixes>"}

      {:ok, fixes} ->
        body =
          fixes
          |> Enum.map(&render_diff/1)
          |> Enum.join("\n")

        {:ok, "<code_fixes>\n#{body}\n</code_fixes>"}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp validate_fix(data) do
    required = ["finding_key", "file_path", "fix_before", "fix_after"]

    missing =
      Enum.filter(required, fn field ->
        val = Map.get(data, field) || Map.get(data, String.to_atom(field))
        is_nil(val) or val == ""
      end)

    if missing == [] do
      :ok
    else
      {:error, "Missing required fix fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp build_fix(data) do
    %{
      finding_key: get_field(data, "finding_key"),
      file_path: get_field(data, "file_path"),
      fix_before: get_field(data, "fix_before"),
      fix_after: get_field(data, "fix_after"),
      language: get_field(data, "language"),
      explanation: get_field(data, "explanation") || "",
      recorded_at: DateTime.utc_now()
    }
  end

  defp get_field(data, key) when is_binary(key) do
    Map.get(data, key) || Map.get(data, String.to_atom(key))
  end
end
