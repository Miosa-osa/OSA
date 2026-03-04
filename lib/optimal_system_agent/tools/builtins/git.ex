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
        "branch, show, stash, reset, remote, tag. " <>
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
            "Git operation: status, diff, log (with optional since/format), commit (stage all + commit), " <>
              "add (stage files), push (push to remote or push tags), pull (pull from remote), " <>
              "clone (clone repo), branch (list/create/switch), show (inspect ref), " <>
              "stash (push/pop/list), reset (unstage/undo), remote (list/add remotes), " <>
              "tag (list/create/delete/push — for semantic versioning)"
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
          "enum" => ["push", "pop", "list"],
          "description" => "Stash action (default: list)"
        },
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

  defp run_operation(op, _dir, _params) do
    {:error,
     "Unknown operation: #{op}. Valid: status, diff, log, commit, add, push, pull, clone, " <>
       "branch, show, stash, reset, remote, tag"}
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
