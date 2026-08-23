defmodule OptimalSystemAgent.Security.EntryFanout do
  @moduledoc """
  Per-entry-point fan-out.

  Discovers request-handler files under a repo root (via `CiScan.discover_entries/2`)
  and builds one bounded whitebox task per file. The parent reviews candidates;
  children do not confirm their own findings and do not probe a live target
  unless RoE is already in the prompt.
  """

  alias OptimalSystemAgent.Security.CiScan

  @default_max 20
  @default_role "security-auditor"

  @type task :: %{
          entry: String.t(),
          subagent_type: String.t(),
          prompt: String.t(),
          success_criteria: String.t()
        }

  @doc """
  Plan one security-auditor child per discovered entry.

  `root` is required and must exist. Options:

    * `:max` (default 20)
    * `:role` (default `"security-auditor"`)
    * `:changed_files` passed through to `CiScan.discover_entries/2` when set
  """
  @spec plan(String.t(), keyword()) :: {:ok, [task()]} | {:error, String.t()}
  def plan(root, opts \\ []) when is_binary(root) do
    if File.dir?(root) do
      max = Keyword.get(opts, :max, @default_max)
      role = Keyword.get(opts, :role, @default_role)

      discover_opts = [max: max]

      discover_opts =
        case Keyword.fetch(opts, :changed_files) do
          {:ok, files} -> Keyword.put(discover_opts, :changed_files, files)
          :error -> discover_opts
        end

      tasks =
        root
        |> CiScan.discover_entries(discover_opts)
        |> Enum.map(&relative_entry(root, &1))
        |> Enum.take(max)
        |> Enum.map(&build_task(&1, role))

      {:ok, tasks}
    else
      {:error, "root is required and must exist"}
    end
  end

  @doc "Numbered list of entries plus the assigned role."
  @spec render([task()]) :: String.t()
  def render(tasks) when is_list(tasks) do
    tasks
    |> Enum.with_index(1)
    |> Enum.map(fn {task, i} -> "#{i}. #{task.entry}  role=#{task.subagent_type}" end)
    |> Enum.join("\n")
  end

  @doc "Shape the OSA `delegate` tool wants: tasks array of prompt + subagent_type."
  @spec delegate_payload([task()]) :: map()
  def delegate_payload(tasks) when is_list(tasks) do
    %{
      "tasks" =>
        Enum.map(tasks, fn task ->
          %{"prompt" => task.prompt, "subagent_type" => task.subagent_type}
        end)
    }
  end

  defp relative_entry(root, path) do
    rel = Path.relative_to(path, root)

    if rel == path do
      path
    else
      rel
    end
  end

  defp build_task(entry, role) do
    %{
      entry: entry,
      subagent_type: role,
      prompt: prompt_for(entry),
      success_criteria: success_criteria()
    }
  end

  defp prompt_for(entry) do
    base = Path.basename(entry)

    """
    Whitebox review of THIS entry only: #{entry} (#{base}).

    Scope: only this entry file and symbols it calls. Do not scan the rest of the repo.

    Method:
    - One vuln class at a time. Basics first: IDOR/authz, then injection (SQLi, XSS, command).
    - For every hop, name the next symbol AND the exact line.
    - Confidence 0-10. Non-remote findings cap at 6.
    - Do not confirm your own finding. Return candidates for the parent to validate.
    - Empty queue for a class is not assessed, not clean.
    - No live target. Do not invent RoE. Probe live only if RoE is already in this prompt (it is not).

    Return: candidates (class, file:line, symbol, sink, chain, confidence, why); next_symbol + line if a hop is unfinished; classes_not_assessed.
    """
    |> String.trim()
  end

  defp success_criteria do
    "Candidates only (no self-confirmed vulns). Each has class, file:line, symbol, confidence 0-10 (non-remote cap 6). Empty class queues marked not assessed, not clean."
  end
end
