defmodule OptimalSystemAgent.Tools.Builtins.EnterWorktree.Handler do
  @moduledoc """
  Validation, permission checking, and execution for `enter_worktree`.

  Creates a git worktree so the agent can operate on an isolated branch.
  The returned path is absolute and ready to be used as a working directory
  for subsequent file/shell tool calls.

  State propagation: the worktree path and branch are embedded in the
  textual result so the model can record them and pass them to exit_worktree
  when done.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Worktree
  alias OptimalSystemAgent.Tools.Builtins.EnterWorktree.Constants
  alias OptimalSystemAgent.Tools.UseContext

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(input, _ctx) when is_map(input) do
    branch = Map.get(input, "branch")
    path = Map.get(input, "path")

    cond do
      branch != nil and not is_binary(branch) ->
        {:error, "branch must be a string", -32_602}

      branch != nil and String.trim(branch) == "" ->
        {:error, "branch must not be blank", -32_602}

      branch != nil and not valid_branch_name?(branch) ->
        {:error,
         "branch contains invalid characters — use letters, digits, hyphens, underscores, and forward slashes only",
         -32_602}

      path != nil and not is_binary(path) ->
        {:error, "path must be a string", -32_602}

      path != nil and String.trim(path) == "" ->
        {:error, "path must not be blank", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(_input, _ctx), do: {:error, "Input must be a map", -32_602}

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, ctx) do
    repo_dir = resolve_repo_dir(ctx)

    case inside_git_repo?(repo_dir) do
      true ->
        {:allow, input}

      false ->
        {:deny,
         "enter_worktree requires a git repository. " <>
           "The current directory (#{repo_dir}) is not inside a git repo."}
    end
  end

  @spec execute(map(), UseContext.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(input, ctx) do
    repo_dir = resolve_repo_dir(ctx)
    branch = Map.get(input, "branch") || generated_branch_name()
    worktrees_dir = Constants.worktrees_dir()
    path = Map.get(input, "path") || Path.join(worktrees_dir, branch)
    path = Path.expand(path)

    # Idempotency guard — error cleanly if the path is already occupied.
    if File.exists?(path) do
      {:error,
       "Worktree already exists at #{path}. " <>
         "Call exit_worktree first to remove it, or specify a different path."}
    else
      File.mkdir_p!(worktrees_dir)
      do_create(path, branch, repo_dir)
    end
  rescue
    e ->
      Logger.error("[enter_worktree] Unexpected error: #{Exception.message(e)}")
      {:error, "enter_worktree error: #{Exception.message(e)}"}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp do_create(path, branch, repo_dir) do
    # `worktree add` performs a checkout, so it fires the *target repo's*
    # `post-checkout` hook — and `repo_dir` is whatever the agent was pointed
    # at, which for a benchmark checkout or a repo delivered as a tarball is
    # attacker-authored. Hooks stay disabled here: this worktree is OSA's own
    # scratch branch, so the repo's checkout hooks have no legitimate claim on
    # it. The user-facing `git` tool is the surface that runs hooks (it passes
    # `hooks: :enabled`), and that distinction is deliberate.
    case OptimalSystemAgent.Git.cmd(
           ["worktree", "add", path, "-b", branch],
           cd: repo_dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        Logger.info("[enter_worktree] Created worktree at #{path} on branch #{branch}")

        # `git worktree add` checks out NOTHING inside a gitlink path — a
        # submodule or embedded independent repo lands as an empty directory, so
        # the model would be handed a worktree with whole components missing and
        # no indication of it. Fill exactly those paths; report if we can't.
        case OptimalSystemAgent.Workspace.FastWorktree.Populate.fill_hidden_subtrees(
               repo_dir,
               path
             ) do
          :ok -> worktree_created_ok(path, branch, repo_dir)
          {:error, reason} -> {:error, "worktree subtree population failed: #{inspect(reason)}"}
        end

      {output, _code} ->
        trimmed = String.trim(output)
        Logger.warning("[enter_worktree] git worktree add failed: #{trimmed}")

        cond do
          trimmed =~ "already exists" ->
            {:error, "Worktree already exists at #{path}."}

          trimmed =~ "already checked out" or trimmed =~ "already been taken" ->
            {:error,
             "Branch '#{branch}' is already checked out in another worktree. " <>
               "Choose a different branch name."}

          true ->
            {:error, "git worktree add failed: #{trimmed}"}
        end
    end
  end

  defp worktree_created_ok(path, branch, repo_dir) do
    run_hooks_async(:worktree_create, %{path: path, branch: branch, repo_dir: repo_dir})

    result =
      "Worktree created.\n" <>
        "  path:   #{path}\n" <>
        "  branch: #{branch}\n\n" <>
        "Use this path as the working directory for subsequent operations. " <>
        "Call exit_worktree(path: \"#{path}\") when done."

    {:ok, result}
  end

  defp inside_git_repo?(dir) do
    case OptimalSystemAgent.Git.cmd(["rev-parse", "--git-dir"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp resolve_repo_dir(%UseContext{extras: %{cwd: cwd}}) when is_binary(cwd), do: cwd
  defp resolve_repo_dir(_ctx), do: File.cwd!()

  defp generated_branch_name do
    ts = System.os_time(:second)
    "osa-wt-#{ts}"
  end

  defp valid_branch_name?(branch) do
    Regex.match?(~r/\A[a-zA-Z0-9._\-\/]+\z/, branch)
  end

  defp run_hooks_async(event, payload) do
    try do
      OptimalSystemAgent.Agent.Hooks.run_async(event, payload)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
