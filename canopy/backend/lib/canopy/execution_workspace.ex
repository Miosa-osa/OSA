defmodule Canopy.ExecutionWorkspace do
  @moduledoc """
  Manages isolated execution workspaces for heartbeat runs.

  Strategies:
  - `:worktree` — git worktree (default, safest)
  - `:shared`   — run in main workspace (no isolation)
  - `:docker`   — spawn container (future)
  - `:sandbox`  — restricted fs (future)
  """

  require Logger

  @type strategy :: :worktree | :shared | :docker | :sandbox

  @type workspace :: %{
          path: String.t(),
          strategy: strategy(),
          branch: String.t() | nil,
          project_path: String.t() | nil,
          cleanup: (-> :ok) | nil
        }

  @doc """
  Create a workspace for the given project path.

  Options:
  - `:strategy` — `:worktree` (default) or `:shared`
  - `:branch_prefix` — prefix for worktree branch name (default: `"canopy-heartbeat"`)
  """
  @spec create(String.t(), keyword()) :: {:ok, workspace()} | {:error, term()}
  def create(project_path, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :worktree)
    branch_prefix = Keyword.get(opts, :branch_prefix, "canopy-heartbeat")

    case strategy do
      :worktree ->
        create_worktree(project_path, branch_prefix)

      :shared ->
        {:ok,
         %{
           path: project_path,
           strategy: :shared,
           branch: nil,
           project_path: project_path,
           cleanup: fn -> :ok end
         }}

      unsupported ->
        {:error, {:unsupported_strategy, unsupported}}
    end
  end

  @doc "Clean up a workspace created by `create/2`."
  @spec cleanup(workspace()) :: :ok
  def cleanup(%{strategy: :worktree, path: path, branch: branch, project_path: project_path}) do
    System.cmd("git", ["worktree", "remove", path, "--force"], cd: project_path)
    System.cmd("git", ["branch", "-D", branch], cd: project_path)
    :ok
  rescue
    _ -> :ok
  end

  def cleanup(%{cleanup: cleanup}) when is_function(cleanup, 0), do: cleanup.()
  def cleanup(_), do: :ok

  defp create_worktree(project_path, prefix) do
    branch = "#{prefix}-#{System.unique_integer([:positive])}"
    worktree_path = Path.join(System.tmp_dir!(), branch)

    case System.cmd(
           "git",
           ["worktree", "add", "-b", branch, worktree_path],
           cd: project_path,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        {:ok,
         %{
           path: worktree_path,
           branch: branch,
           project_path: project_path,
           strategy: :worktree,
           cleanup: nil
         }}

      {output, code} ->
        Logger.warning("Failed to create git worktree: exit=#{code} output=#{output}")
        {:error, {:worktree_failed, code, output}}
    end
  end
end
