defmodule OptimalSystemAgent.Tools.Builtins.Github do
  @behaviour MiosaTools.Behaviour

  @allowed_commands ~w(
    pr_create pr_list pr_view pr_merge
    issue_create issue_list issue_view issue_comment
    repo_view run_list run_view
    file_read file_write file_list
  )

  @gh_timeout 30_000

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "github"

  @impl true
  def description,
    do:
      "Interact with GitHub — read/write files in any repo, create PRs, list issues, view CI runs. " <>
        "Supports any repo via the repo param (e.g. 'owner/name'). " <>
        "Requires gh (GitHub CLI) to be installed and authenticated."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "enum" => @allowed_commands,
          "description" =>
            "GitHub operation: " <>
              "file_read: read a file from any repo. " <>
              "file_write: create or update a file (commits the change). " <>
              "file_list: list directory contents. " <>
              "pr_create, pr_list, pr_view, pr_merge, " <>
              "issue_create, issue_list, issue_view, issue_comment, repo_view, run_list, run_view"
        },
        "repo" => %{
          "type" => "string",
          "description" =>
            "Target repository in owner/name format (e.g. 'robertohluna/BOS'). " <>
              "Defaults to the repo of the current working directory."
        },
        "args" => %{
          "type" => "object",
          "description" =>
            "Command-specific arguments. " <>
              "file_read: {path}. " <>
              "file_write: {path, content, message, branch?}. " <>
              "file_list: {path?}. " <>
              "pr_create: {title, body, base?, draft?}. " <>
              "pr_list: {state?, limit?}. " <>
              "pr_view: {number, json?}. " <>
              "pr_merge: {number, method?}. " <>
              "issue_create: {title, body, label?}. " <>
              "issue_list: {state?, limit?}. " <>
              "issue_view: {number}. " <>
              "issue_comment: {number, body}. " <>
              "repo_view: {json?}. " <>
              "run_list: {limit?}. " <>
              "run_view: {run_id}"
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  # Deferred: discoverable mid-turn via `tool_search`, absent from the default
  # toolbox. Every schema in the default set is re-sent on EVERY request, so a
  # tool most turns never touch is paid for by all of them.
  @impl true
  def should_defer?, do: true

  def available? do
    System.find_executable("gh") != nil
  end

  @impl true
  def execute(%{"command" => command} = params) do
    with :ok <- validate_command(command),
         :ok <- check_gh_installed(),
         :ok <- check_gh_auth() do
      args_map = Map.get(params, "args", %{}) || %{}
      repo = Map.get(params, "repo")
      run_command(command, args_map, repo)
    end
  end

  def execute(_), do: {:error, "Missing required parameter: command"}

  # --- Command dispatch ---

  defp run_command("file_read", args, repo) do
    path = Map.get(args, "path")

    if is_nil(path) or path == "" do
      {:error, "file_read requires: path"}
    else
      endpoint = repo_api_path(repo, "contents/#{path}")

      case gh_api(["api", endpoint, "--jq", ".content,.encoding,.sha"]) do
        {:ok, raw} ->
          [content_b64, encoding, sha] =
            raw |> String.trim() |> String.split("\n") |> Enum.take(3) |> pad_to(3)

          content =
            if encoding == "base64" do
              content_b64
              |> String.replace("\n", "")
              |> Base.decode64!()
            else
              content_b64
            end

          {:ok, %{path: path, content: content, sha: String.trim(sha || "")}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp run_command("file_write", args, repo) do
    path = Map.get(args, "path")
    content = Map.get(args, "content")
    message = Map.get(args, "message") || "chore: update #{path} via OSA"

    cond do
      is_nil(path) or path == "" ->
        {:error, "file_write requires: path"}

      is_nil(content) ->
        {:error, "file_write requires: content"}

      true ->
        endpoint = repo_api_path(repo, "contents/#{path}")
        content_b64 = Base.encode64(content)

        # Try to get current SHA (needed for updates; omitted for new files)
        sha_args =
          case gh_api(["api", endpoint, "--jq", ".sha"]) do
            {:ok, sha} -> ["-f", "sha=#{String.trim(sha)}"]
            {:error, _} -> []
          end

        put_args =
          [
            "api",
            endpoint,
            "-X",
            "PUT",
            "-f",
            "message=#{message}",
            "-f",
            "content=#{content_b64}"
          ] ++
            sha_args ++
            maybe_branch_args(args["branch"])

        case gh_api(put_args) do
          {:ok, _} ->
            {:ok, %{status: "committed", path: path, message: message}}

          {:error, _} = err ->
            err
        end
    end
  end

  defp run_command("file_list", args, repo) do
    path = Map.get(args, "path") || ""
    endpoint = repo_api_path(repo, "contents/#{path}")

    case gh_api(["api", endpoint, "--jq", "[.[] | {name, type, path, size}]"]) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, entries} -> {:ok, %{path: path, entries: entries, count: length(entries)}}
          _ -> {:ok, %{path: path, raw: json}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp run_command("pr_create", args, repo) do
    title = Map.get(args, "title")
    body = Map.get(args, "body")

    if is_nil(title) or title == "" do
      {:error, "pr_create requires: title"}
    else
      cli_args =
        ["pr", "create", "--title", title, "--body", body || ""]
        |> maybe_append(args["base"], "--base", args["base"])
        |> maybe_flag(args["draft"], "--draft")
        |> with_repo(repo)

      gh(cli_args)
    end
  end

  defp run_command("pr_list", args, repo) do
    cli_args =
      ["pr", "list"]
      |> maybe_append(args["state"], "--state", args["state"])
      |> maybe_append(args["limit"], "--limit", to_string(args["limit"] || ""))
      |> with_repo(repo)

    gh(cli_args)
  end

  defp run_command("pr_view", args, repo) do
    number = Map.get(args, "number")

    if is_nil(number) do
      {:error, "pr_view requires: number"}
    else
      cli_args =
        ["pr", "view", to_string(number)]
        |> maybe_append(args["json"], "--json", args["json"])
        |> with_repo(repo)

      gh(cli_args)
    end
  end

  defp run_command("pr_merge", args, repo) do
    number = Map.get(args, "number")

    if is_nil(number) do
      {:error, "pr_merge requires: number"}
    else
      method = args["method"] || "merge"

      flag =
        case method do
          "squash" -> "--squash"
          "rebase" -> "--rebase"
          _ -> "--merge"
        end

      gh(["pr", "merge", to_string(number), flag] |> with_repo(repo))
    end
  end

  defp run_command("issue_create", args, repo) do
    title = Map.get(args, "title")
    body = Map.get(args, "body")

    if is_nil(title) or title == "" do
      {:error, "issue_create requires: title"}
    else
      cli_args =
        ["issue", "create", "--title", title, "--body", body || ""]
        |> maybe_append(args["label"], "--label", args["label"])
        |> with_repo(repo)

      gh(cli_args)
    end
  end

  defp run_command("issue_list", args, repo) do
    cli_args =
      ["issue", "list"]
      |> maybe_append(args["state"], "--state", args["state"])
      |> maybe_append(args["limit"], "--limit", to_string(args["limit"] || ""))
      |> with_repo(repo)

    gh(cli_args)
  end

  defp run_command("issue_view", args, repo) do
    number = Map.get(args, "number")

    if is_nil(number) do
      {:error, "issue_view requires: number"}
    else
      gh(["issue", "view", to_string(number)] |> with_repo(repo))
    end
  end

  defp run_command("issue_comment", args, repo) do
    number = Map.get(args, "number")
    body = Map.get(args, "body")

    cond do
      is_nil(number) -> {:error, "issue_comment requires: number"}
      is_nil(body) or body == "" -> {:error, "issue_comment requires: body"}
      true -> gh(["issue", "comment", to_string(number), "--body", body] |> with_repo(repo))
    end
  end

  defp run_command("repo_view", args, repo) do
    cli_args =
      ["repo", "view"]
      |> maybe_append(args["json"], "--json", args["json"])
      |> with_repo(repo)

    gh(cli_args)
  end

  defp run_command("run_list", args, repo) do
    cli_args =
      ["run", "list"]
      |> maybe_append(args["limit"], "--limit", to_string(args["limit"] || ""))
      |> with_repo(repo)

    gh(cli_args)
  end

  defp run_command("run_view", args, repo) do
    run_id = Map.get(args, "run_id")

    if is_nil(run_id) do
      {:error, "run_view requires: run_id"}
    else
      gh(["run", "view", to_string(run_id)] |> with_repo(repo))
    end
  end

  defp run_command(cmd, _args, _repo) do
    {:error, "Unknown command: #{cmd}. Valid: #{Enum.join(@allowed_commands, ", ")}"}
  end

  # --- Helpers ---

  # Build GitHub API path for a given repo and sub-path.
  # When repo is nil, falls back to the detected repo of cwd via gh api.
  defp repo_api_path(nil, sub), do: "repos/{owner}/{repo}/#{sub}"
  defp repo_api_path(repo, sub), do: "repos/#{repo}/#{sub}"

  # Append --repo flag when a repo is specified.
  defp with_repo(args, nil), do: args
  defp with_repo(args, repo), do: args ++ ["--repo", repo]

  # gh api helper — uses gh CLI to call REST endpoints.
  defp gh_api(args) do
    task =
      Task.async(fn ->
        System.cmd("gh", args,
          stderr_to_stdout: true,
          cd: OptimalSystemAgent.Workspace.Cwd.get(),
          env: gh_env()
        )
      end)

    case Task.yield(task, @gh_timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        out = String.trim(output)
        {:ok, if(out == "", do: "(no output)", else: out)}

      {:ok, {output, _code}} ->
        {:error, String.trim(output)}

      nil ->
        {:error, "gh api timed out after #{div(@gh_timeout, 1000)}s"}
    end
  rescue
    e -> {:error, "gh api failed: #{Exception.message(e)}"}
  end

  # Append branch args for file_write when branch is specified.
  defp maybe_branch_args(nil), do: []
  defp maybe_branch_args(""), do: []
  defp maybe_branch_args(branch), do: ["-f", "branch=#{branch}"]

  # Environment for every `gh` invocation.
  #
  # `gh` is the one child here that legitimately needs a credential, so the
  # scrub cannot be blanket: `GH_TOKEN`/`GITHUB_TOKEN` (and the Enterprise
  # variants plus `GH_HOST`, which selects the server) are re-exported on top
  # of it. Everything else — provider API keys, gateway tokens — is unset, so
  # `gh` and any helper it shells out to see only GitHub's own credential.
  @gh_passthrough ~w(GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
                     GH_HOST GH_CONFIG_DIR)
  defp gh_env,
    do: OptimalSystemAgent.OS.Env.cmd_env(OptimalSystemAgent.OS.Env.keep(@gh_passthrough))

  # Pad a list to n elements with nil.
  defp pad_to(list, n) when length(list) >= n, do: list
  defp pad_to(list, n), do: list ++ List.duplicate(nil, n - length(list))

  defp gh(args) do
    task =
      Task.async(fn ->
        System.cmd("gh", args,
          stderr_to_stdout: true,
          cd: OptimalSystemAgent.Workspace.Cwd.get(),
          env: gh_env()
        )
      end)

    case Task.yield(task, @gh_timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        out = String.trim(output)
        {:ok, if(out == "", do: "(no output)", else: out)}

      {:ok, {output, _code}} ->
        {:error, String.trim(output)}

      nil ->
        {:error, "gh command timed out after #{div(@gh_timeout, 1000)}s"}
    end
  rescue
    e -> {:error, "gh command failed: #{Exception.message(e)}"}
  end

  defp validate_command(command) do
    if command in @allowed_commands do
      :ok
    else
      {:error,
       "Unknown command: #{command}. Valid commands: #{Enum.join(@allowed_commands, ", ")}"}
    end
  end

  defp check_gh_installed do
    case System.find_executable("gh") do
      nil ->
        {:error, "gh (GitHub CLI) is not installed. Install from https://cli.github.com/"}

      _ ->
        :ok
    end
  end

  defp check_gh_auth do
    case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true, env: gh_env()) do
      {_, 0} ->
        :ok

      {output, _} ->
        trimmed = String.trim(output)

        if String.contains?(trimmed, "not logged") or String.contains?(trimmed, "unauthenticated") do
          {:error, "gh is not authenticated. Run: gh auth login"}
        else
          # auth status sometimes exits non-zero but is still valid; treat as ok
          :ok
        end
    end
  rescue
    _ -> {:error, "Could not verify gh authentication status"}
  end

  # Append [flag, value] to list only when condition is truthy and value is non-empty.
  defp maybe_append(list, condition, flag, value) do
    if condition && value != nil && value != "" do
      list ++ [flag, to_string(value)]
    else
      list
    end
  end

  # Append a boolean flag to the list only when condition is truthy.
  defp maybe_flag(list, condition, flag) do
    if condition, do: list ++ [flag], else: list
  end
end
