defmodule OptimalSystemAgent.Tools.Builtins.Git do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  require Logger

  @default_allowed_paths ["~", "/tmp"]

  @impl true
  def name, do: "git"

  @impl true
  def description,
    do:
      "Run git operations in a repository: status, diff, log, commit, add, push, pull, clone, " <>
        "branch, show, stash, reset, remote, tag, " <>
        "blame (line authorship), search (grep+pickaxe history mining), cherry_pick, worktree, bisect, reflog, pr_diff. " <>
        "Safe — runs specific git subcommands only, no arbitrary shell execution."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "operation" => %{
          "type" => "string",
          "enum" => [
            "status", "diff", "log", "commit", "add",
            "push", "pull", "clone", "branch", "show",
            "stash", "reset", "remote", "tag"
          ],
          "description" =>
            "Git operation: status, diff, log, commit, add, push, pull, clone, branch, show, " <>
              "stash (push/pop/list/drop), reset, remote, tag, " <>
              "blame (line authorship), search (grep+pickaxe), cherry_pick, worktree, bisect, reflog, pr_diff"
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Working directory (git repo root). Defaults to ~/.osa/workspace if it exists, else ~."
        },
        "message" => %{
          "type" => "string",
          "description" => "Commit message (required for commit operation)"
        },
        "file" => %{
          "type" => "string",
          "description" => "File path for diff (relative or absolute). Omit to diff all changes."
        },
        "files" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of files to stage (for add operation). Omit to stage all."
        },
        "count" => %{
          "type" => "integer",
          "description" => "Number of log entries to show (for log operation, default: 15)"
        },
        "since" => %{
          "type" => "string",
          "description" =>
            "Show commits since this ref/tag (for log operation). " <>
              "E.g., 'v1.0.0' shows commits after that tag. Useful for changelog/versioning."
        },
        "format" => %{
          "type" => "string",
          "enum" => ["oneline", "full", "conventional"],
          "description" =>
            "Log format (for log operation). oneline=short hash+subject (default), " <>
              "full=full commit details, conventional=grouped by feat/fix/chore for changelog"
        },
        "tag_name" => %{
          "type" => "string",
          "description" => "Tag name (for tag operation, e.g. 'v1.2.3')"
        },
        "tag_message" => %{
          "type" => "string",
          "description" => "Tag annotation message (for tag create — creates annotated tag)"
        },
        "tag_action" => %{
          "type" => "string",
          "enum" => ["list", "create", "delete", "push", "latest"],
          "description" =>
            "Tag action: list (all tags), create (new tag), delete (remove tag), " <>
              "push (push tag to remote), latest (get most recent semver tag). Default: list."
        },
        "ref" => %{
          "type" => "string",
          "description" => "Git ref or commit hash to inspect (for show operation, default: HEAD)"
        },
        "branch_name" => %{
          "type" => "string",
          "description" => "Branch name to create/switch to (for branch operation)"
        },
        "stash_action" => %{
          "type" => "string",
          "enum" => ["push", "pop", "list", "drop"],
          "description" => "Stash action (default: list)"
        },
        "line_start" => %{"type" => "integer", "description" => "Start line for blame range"},
        "line_end" => %{"type" => "integer", "description" => "End line for blame range"},
        "query" => %{"type" => "string", "description" => "Search query (for search operation)"},
        "search_type" => %{
          "type" => "string",
          "enum" => ["grep", "pickaxe", "both"],
          "description" => "Search type: grep=commit messages, pickaxe=code changes, both=default"
        },
        "worktree_action" => %{
          "type" => "string",
          "enum" => ["list", "add", "remove"],
          "description" => "Worktree action (default: list)"
        },
        "worktree_path" => %{"type" => "string", "description" => "Path for worktree add/remove"},
        "bisect_action" => %{
          "type" => "string",
          "enum" => ["start", "good", "bad", "reset", "log", "run"],
          "description" => "Bisect action"
        },
        "bisect_command" => %{"type" => "string", "description" => "Test command for bisect run"},
        "good_ref" => %{"type" => "string", "description" => "Known-good ref for bisect start"},
        "bad_ref" => %{"type" => "string", "description" => "Known-bad ref for bisect start (default: HEAD)"},
        "base_branch" => %{"type" => "string", "description" => "Base branch for pr_diff (default: main)"},
        "no_commit" => %{"type" => "boolean", "description" => "cherry_pick without committing (stage only)"},
        "remote" => %{
          "type" => "string",
          "description" => "Remote name for push/pull (default: origin)"
        },
        "branch_ref" => %{
          "type" => "string",
          "description" => "Branch to push/pull (default: current branch HEAD)"
        },
        "set_upstream" => %{
          "type" => "boolean",
          "description" => "Set upstream tracking for push (git push -u remote branch)"
        },
        "url" => %{
          "type" => "string",
          "description" => "Repository URL for clone or remote add"
        },
        "remote_name" => %{
          "type" => "string",
          "description" => "Remote name to add (for remote operation, default: origin)"
        },
        "reset_mode" => %{
          "type" => "string",
          "enum" => ["soft", "mixed", "hard"],
          "description" => "Reset mode (default: mixed). soft=keep staged, mixed=unstage, hard=discard all"
        }
      },
      "required" => ["operation"]
    }
  end

  @impl true
  def execute(%{"operation" => operation} = params) do
    work_dir = resolve_work_dir(params["path"])

    case validate_path(work_dir) do
      :ok ->
        case ensure_repo(work_dir) do
          :ok -> run_operation(operation, work_dir, params)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_), do: {:error, "Missing required parameter: operation"}

  # --- Operations ---

  defp run_operation("status", dir, _params) do
    git(["status", "--short", "--branch"], dir)
  end

  defp run_operation("diff", dir, params) do
    args =
      case params["file"] do
        nil -> ["diff"]
        file -> ["diff", "--", file]
      end

    git(args, dir)
  end

  defp run_operation("log", dir, params) do
    count = params["count"] || 15
    format = params["format"] || "oneline"
    since = params["since"]

    case format do
      "conventional" ->
        # Group commits by type for changelog generation
        range = if since, do: "#{since}..HEAD", else: "HEAD"

        case git(["log", "--pretty=format:%s", range], dir) do
          {:ok, output} ->
            grouped = group_by_conventional_type(output)
            {:ok, grouped}

          error ->
            error
        end

      "full" ->
        args =
          if since,
            do: ["log", "--stat", "#{since}..HEAD"],
            else: ["log", "--stat", "-#{count}"]

        git(args, dir)

      _ ->
        # Default: oneline graph
        args =
          if since,
            do: ["log", "--oneline", "#{since}..HEAD"],
            else: ["log", "--oneline", "--graph", "-#{count}"]

        git(args, dir)
    end
  end

  defp run_operation("commit", dir, params) do
    case params["message"] do
      nil ->
        {:error, "commit requires a message parameter"}

      "" ->
        {:error, "commit message cannot be empty"}

      message ->
        # Stage all tracked + new files, then commit
        case git(["add", "-A"], dir) do
          {:ok, _} ->
            case git(["commit", "-m", message], dir) do
              {:ok, output} ->
                {:ok, output}

              {:error, output} ->
                # Nothing to commit is not a fatal error
                if String.contains?(output, "nothing to commit") do
                  {:ok, output}
                else
                  {:error, output}
                end
            end

          {:error, reason} ->
            {:error, "git add failed: #{reason}"}
        end
    end
  end

  defp run_operation("branch", dir, params) do
    case params["branch_name"] do
      nil ->
        # List all branches with current highlighted
        git(["branch", "-a"], dir)

      name ->
        # Create and switch to new branch
        case git(["checkout", "-b", name], dir) do
          {:ok, output} -> {:ok, output}
          # Branch already exists — just switch
          {:error, _} -> git(["checkout", name], dir)
        end
    end
  end

  defp run_operation("show", dir, params) do
    ref = params["ref"] || "HEAD"
    git(["show", "--stat", ref], dir)
  end

  defp run_operation("add", dir, params) do
    files = params["files"]

    args =
      case files do
        nil -> ["add", "-A"]
        [] -> ["add", "-A"]
        list -> ["add" | list]
      end

    git(args, dir)
  end

  defp run_operation("push", dir, params) do
    remote = params["remote"] || "origin"
    set_upstream = params["set_upstream"] == true

    args =
      case params["branch_ref"] do
        nil when set_upstream ->
          # Push current branch with upstream tracking
          ["push", "-u", remote, "HEAD"]

        nil ->
          ["push", remote]

        branch when set_upstream ->
          ["push", "-u", remote, branch]

        branch ->
          ["push", remote, branch]
      end

    git(args, dir)
  end

  defp run_operation("pull", dir, params) do
    remote = params["remote"] || "origin"

    args =
      case params["branch_ref"] do
        nil -> ["pull", remote]
        branch -> ["pull", remote, branch]
      end

    git(args, dir)
  end

  defp run_operation("clone", _dir, params) do
    case params["url"] do
      nil ->
        {:error, "clone requires a url parameter"}

      url ->
        target =
          case params["path"] do
            nil ->
              workspace = Path.expand("~/.osa/workspace")
              File.mkdir_p!(workspace)
              # Default: clone into workspace/<repo-name>
              repo_name =
                url
                |> String.split("/")
                |> List.last()
                |> String.replace_suffix(".git", "")

              Path.join(workspace, repo_name)

            path ->
              Path.expand(path)
          end

        case validate_path(target) do
          :ok ->
            File.mkdir_p!(Path.dirname(target))
            git(["clone", url, target], Path.expand("~"))

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp run_operation("reset", dir, params) do
    mode = params["reset_mode"] || "mixed"

    mode_flag =
      case mode do
        "soft" -> "--soft"
        "hard" -> "--hard"
        _ -> "--mixed"
      end

    args =
      case params["file"] do
        nil -> ["reset", mode_flag, "HEAD"]
        file -> ["reset", "HEAD", "--", file]
      end

    git(args, dir)
  end

  defp run_operation("remote", dir, params) do
    case params["url"] do
      nil ->
        # List remotes
        git(["remote", "-v"], dir)

      url ->
        # Add remote
        name = params["remote_name"] || "origin"
        git(["remote", "add", name, url], dir)
    end
  end

  defp run_operation("stash", dir, params) do
    action = params["stash_action"] || "list"

    case action do
      "push" -> git(["stash", "push"], dir)
      "pop" -> git(["stash", "pop"], dir)
      "list" -> git(["stash", "list"], dir)
      other -> {:error, "Unknown stash action: #{other}. Use push, pop, or list."}
    end
  end

  defp run_operation("tag", dir, params) do
    action = params["tag_action"] || "list"

    case action do
      "list" ->
        # List tags sorted by version (semver-aware)
        git(["tag", "--sort=-version:refname"], dir)

      "latest" ->
        # Get the most recent semver tag
        case git(["describe", "--tags", "--abbrev=0"], dir) do
          {:ok, tag} -> {:ok, tag}
          {:error, _} -> {:ok, "(no tags yet)"}
        end

      "create" ->
        case params["tag_name"] do
          nil ->
            {:error, "tag create requires tag_name parameter"}

          name ->
            args =
              case params["tag_message"] do
                nil -> ["tag", name]
                msg -> ["tag", "-a", name, "-m", msg]
              end

            git(args, dir)
        end

      "delete" ->
        case params["tag_name"] do
          nil -> {:error, "tag delete requires tag_name parameter"}
          name -> git(["tag", "-d", name], dir)
        end

      "push" ->
        remote = params["remote"] || "origin"

        args =
          case params["tag_name"] do
            nil -> ["push", remote, "--tags"]
            name -> ["push", remote, name]
          end

        git(args, dir)

      other ->
        {:error, "Unknown tag action: #{other}. Use list, create, delete, push, or latest."}
    end
  end

  defp run_operation("blame", dir, params) do
    case params["file"] do
      nil -> {:error, "blame requires a file parameter"}
      file ->
        args = case {params["line_start"], params["line_end"]} do
          {nil, _} -> ["blame", "--", file]
          {s, nil} -> ["blame", "-L", "#{s},#{s}", "--", file]
          {s, e}   -> ["blame", "-L", "#{s},#{e}", "--", file]
        end
        case git(args, dir) do
          {:ok, out} -> {:ok, "Blame for #{file}:\n#{out}"}
          error -> error
        end
    end
  end

  defp run_operation("search", dir, params) do
    case params["query"] do
      nil -> {:error, "search requires a query parameter"}
      query ->
        type = params["search_type"] || "both"
        grep_r = if type in ["grep", "both"], do: git(["log", "--all", "--oneline", "--grep=#{query}"], dir), else: nil
        pick_r = if type in ["pickaxe", "both"], do: git(["log", "--all", "--oneline", "-S", query], dir), else: nil
        case {grep_r, pick_r} do
          {nil, {:ok, o}}       -> {:ok, "Pickaxe (code changes):\n#{o}"}
          {{:ok, o}, nil}       -> {:ok, "Message matches:\n#{o}"}
          {{:ok, g}, {:ok, p}}  -> {:ok, "Message matches:\n#{g}\n\nCode changes (pickaxe):\n#{p}"}
          {{:error, e}, _}      -> {:error, e}
          {_, {:error, e}}      -> {:error, e}
        end
    end
  end

  defp run_operation("cherry_pick", dir, params) do
    case params["ref"] do
      nil -> {:error, "cherry_pick requires a ref parameter (commit SHA or space-separated list)"}
      ref ->
        shas = String.split(ref, ~r/\s+/, trim: true)
        base = if params["no_commit"] == true, do: ["cherry-pick", "--no-commit"], else: ["cherry-pick"]
        case git(base ++ shas, dir) do
          {:ok, o} -> {:ok, o}
          {:error, o} ->
            if String.contains?(o, "CONFLICT"),
              do: {:error, "Conflict detected. Resolve, then `git cherry-pick --continue`.\n#{o}"},
              else: {:error, o}
        end
    end
  end

  defp run_operation("worktree", dir, params) do
    case params["worktree_action"] || "list" do
      "list" ->
        git(["worktree", "list"], dir)
      "add" ->
        case params["worktree_path"] do
          nil -> {:error, "worktree add requires worktree_path"}
          wt_path ->
            expanded = if Path.type(wt_path) == :relative,
              do: Path.expand(Path.join("~/.osa/workspace", wt_path)),
              else: Path.expand(wt_path)
            args = case params["branch_name"] do
              nil    -> ["worktree", "add", "-b", Path.basename(expanded), expanded]
              branch -> ["worktree", "add", expanded, branch]
            end
            git(args, dir)
        end
      "remove" ->
        case params["worktree_path"] do
          nil -> {:error, "worktree remove requires worktree_path"}
          wt_path -> git(["worktree", "remove", Path.expand(wt_path)], dir)
        end
      other -> {:error, "Unknown worktree_action: #{other}. Use list, add, or remove."}
    end
  end

  @safe_bisect_executables ~w(mix elixir cargo go npm yarn pytest python python3 ruby bash sh)

  defp run_operation("bisect", dir, params) do
    case params["bisect_action"] || "log" do
      "start" ->
        bad = params["bad_ref"] || "HEAD"
        with {:ok, _} <- git(["bisect", "start"], dir),
             {:ok, _} <- git(["bisect", "bad", bad], dir),
             {:ok, out} <- case params["good_ref"] do
               nil -> {:ok, "Mark good commits with bisect_action=good"}
               g   -> git(["bisect", "good", g], dir)
             end do
          {:ok, "Bisect started. bad=#{bad}.\n#{out}"}
        end
      "good"  -> git(["bisect", "good"], dir)
      "bad"   -> git(["bisect", "bad"], dir)
      "reset" -> git(["bisect", "reset"], dir)
      "log"   ->
        case git(["bisect", "log"], dir) do
          {:ok, o} -> {:ok, o}
          {:error, _} -> {:ok, "No bisect in progress."}
        end
      "run" ->
        case params["bisect_command"] do
          nil -> {:error, "bisect run requires bisect_command"}
          cmd ->
            [exe | rest] = String.split(String.trim(cmd), ~r/\s+/, trim: true)
            if Path.basename(exe) in @safe_bisect_executables do
              case System.cmd(exe, rest, cd: dir, stderr_to_stdout: true) do
                {out, 0}    -> {:ok, "bisect run exit 0:\n#{out}"}
                {out, code} -> {:error, "bisect run exit #{code}:\n#{out}"}
              end
            else
              {:error, "bisect_command '#{exe}' not allowed. Use: #{Enum.join(@safe_bisect_executables, ", ")}"}
            end
        end
      other -> {:error, "Unknown bisect_action: #{other}"}
    end
  end

  defp run_operation("reflog", dir, params) do
    count = params["count"] || 20
    ref = params["ref"] || "HEAD"
    case git(["reflog", "--oneline", "-#{count}", ref], dir) do
      {:ok, out} -> {:ok, "Reflog for #{ref} (last #{count}):\n#{out}\n\nTo restore: git checkout -b <branch> <sha>"}
      error -> error
    end
  end

  defp run_operation("pr_diff", dir, params) do
    base = params["base_branch"] || "main"
    case git(["diff", "#{base}...HEAD"], dir) do
      {:ok, o} -> {:ok, "PR diff (#{base}...HEAD):\n#{o}"}
      {:error, _} ->
        case git(["diff", "origin/#{base}...HEAD"], dir) do
          {:ok, o} -> {:ok, "PR diff (origin/#{base}...HEAD):\n#{o}"}
          error -> error
        end
    end
  end

  defp run_operation(op, _dir, _params) do
    {:error,
     "Unknown operation: #{op}. Valid: status, diff, log, commit, add, push, pull, clone, " <>
       "branch, show, stash, reset, remote, tag, blame, search, cherry_pick, worktree, bisect, reflog, pr_diff"}
  end

  # --- Helpers ---

  # Groups commit subjects by conventional commit type for changelog output.
  # Input: newline-separated commit subjects
  # Output: formatted changelog sections
  defp group_by_conventional_type(""), do: "(no commits)"
  defp group_by_conventional_type("(no output)"), do: "(no commits)"

  defp group_by_conventional_type(output) do
    lines = String.split(output, "\n", trim: true)

    groups =
      Enum.group_by(lines, fn line ->
        cond do
          String.match?(line, ~r/^feat(\(.+\))?!?:/) -> :breaking
          String.match?(line, ~r/^.+(\(.+\))?!:/) -> :breaking
          String.match?(line, ~r/^feat(\(.+\))?:/) -> :feat
          String.match?(line, ~r/^fix(\(.+\))?:/) -> :fix
          String.match?(line, ~r/^perf(\(.+\))?:/) -> :perf
          String.match?(line, ~r/^refactor(\(.+\))?:/) -> :refactor
          String.match?(line, ~r/^docs(\(.+\))?:/) -> :docs
          String.match?(line, ~r/^test(\(.+\))?:/) -> :test
          String.match?(line, ~r/^chore(\(.+\))?:/) -> :chore
          true -> :other
        end
      end)

    sections = [
      {:breaking, "### BREAKING CHANGES"},
      {:feat, "### Features"},
      {:fix, "### Bug Fixes"},
      {:perf, "### Performance"},
      {:refactor, "### Refactor"},
      {:docs, "### Docs"},
      {:test, "### Tests"},
      {:chore, "### Chore"},
      {:other, "### Other"}
    ]

    result =
      Enum.flat_map(sections, fn {key, header} ->
        case Map.get(groups, key) do
          nil -> []
          commits -> [header | Enum.map(commits, fn c -> "- #{c}" end)] ++ [""]
        end
      end)

    case result do
      [] -> "(no conventional commits found)"
      lines -> Enum.join(lines, "\n")
    end
  end

  defp git(args, dir) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} ->
        out = String.trim(output)
        {:ok, if(out == "", do: "(no output)", else: out)}

      {output, _code} ->
        {:error, String.trim(output)}
    end
  rescue
    e -> {:error, "git command failed: #{Exception.message(e)}"}
  end

  # Ensure the directory is a git repo — initialize it if not.
  # Sets minimal local config (user.name/email) so commits work without global config.
  defp ensure_repo(dir) do
    case git(["rev-parse", "--git-dir"], dir) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Logger.info("[git] No repo found at #{dir} — initializing")

        with {:ok, _} <- git(["init"], dir),
             {:ok, _} <- git(["config", "user.email", "osa@local"], dir),
             {:ok, _} <- git(["config", "user.name", "OSA"], dir) do
          :ok
        else
          {:error, reason} -> {:error, "git init failed: #{reason}"}
        end
    end
  end

  defp resolve_work_dir(nil) do
    workspace = Path.expand("~/.osa/workspace")
    if File.dir?(workspace), do: workspace, else: Path.expand("~")
  end

  defp resolve_work_dir(path), do: Path.expand(path)

  defp validate_path(expanded_path) do
    allowed =
      Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)
      |> Enum.map(fn p ->
        e = Path.expand(p)
        if String.ends_with?(e, "/"), do: e, else: e <> "/"
      end)

    check =
      if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

    if Enum.any?(allowed, fn a -> String.starts_with?(check, a) end) do
      :ok
    else
      {:error, "Access denied: #{expanded_path} is outside allowed paths"}
    end
  end
end
