defmodule OptimalSystemAgent.Channels.HTTP.API.WorkspaceRoutes do
  @moduledoc """
  Workspace introspection routes.

  Forwarded from /workspace in the parent API router.

  Effective endpoints:
    GET /workspace  (forwarded as GET /)
      Returns:
        - cwd         : current working directory
        - git_status  : short git status lines (empty list when not a git repo)
        - git_log     : last 5 commit oneline summaries (empty list when not a git repo)
        - directories      : top-level directory names in cwd
        - files            : top-level regular file names in cwd
        - project_name     : basename of cwd
        - project_type     : coarse detected project type
        - git_branch       : current branch, nil outside git repositories
        - git_dirty        : true when git status has changes
        - session_count    : recent saved session count
        - memory_count     : persisted memory entry count when available
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / ─────────────────────────────────────────────────────────────────

  get "/" do
    cwd = File.cwd!()

    {git_status, git_log, git_branch} = fetch_git_info(cwd)

    {dirs, files} =
      try do
        entries = File.ls!(cwd)

        Enum.split_with(entries, fn name ->
          File.dir?(Path.join(cwd, name))
        end)
      rescue
        e ->
          Logger.warning(
            "[WorkspaceRoutes] Failed to list directory #{cwd}: #{Exception.message(e)}"
          )

          {[], []}
      end

    body =
      Jason.encode!(%{
        cwd: cwd,
        project_name: Path.basename(cwd),
        project_type: detect_project_type(files),
        git_status: git_status,
        git_log: git_log,
        git_branch: git_branch,
        git_dirty: git_status != [],
        directories: Enum.sort(dirs),
        files: Enum.sort(files),
        session_count: session_count(),
        memory_count: memory_count()
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /ls?path=<dir> ─────────────────────────────────────────────────────
  # Browse any directory relative to cwd. Used by the FileTree component.

  get "/ls" do
    conn = Plug.Conn.fetch_query_params(conn)
    cwd = File.cwd!()
    req_path = conn.query_params["path"] || "."

    # Resolve and validate path is within cwd (prevent directory traversal)
    resolved = Path.expand(req_path, cwd)

    unless String.starts_with?(resolved, cwd) do
      json_error(conn, 403, "forbidden", "Path is outside the workspace")
    else
      if File.dir?(resolved) do
        entries =
          try do
            File.ls!(resolved)
            |> Enum.reject(&String.starts_with?(&1, "."))
            |> Enum.reject(
              &(&1 in ~w(node_modules _build deps .git .elixir_ls __pycache__ .next .svelte-kit target vendor))
            )
            |> Enum.map(fn name ->
              full = Path.join(resolved, name)
              rel = Path.relative_to(full, cwd)
              type = if File.dir?(full), do: "directory", else: "file"

              stat =
                try do
                  %File.Stat{size: size} = File.stat!(full)
                  %{size: size}
                rescue
                  _ -> %{size: 0}
                end

              git_status = git_file_status(cwd, rel)

              %{name: name, path: rel, type: type, size: stat.size, git_status: git_status}
            end)
            |> Enum.sort_by(fn e -> {if(e.type == "directory", do: 0, else: 1), e.name} end)
          rescue
            e ->
              Logger.warning(
                "[WorkspaceRoutes] Failed to list #{resolved}: #{Exception.message(e)}"
              )

              []
          end

        body = Jason.encode!(%{entries: entries, path: Path.relative_to(resolved, cwd)})
        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
      else
        json_error(conn, 404, "not_found", "Directory not found: #{req_path}")
      end
    end
  end

  # ── GET /read?path=<file> ────────────────────────────────────────────────
  # Read file content. Used by the file preview panel.

  get "/read" do
    conn = Plug.Conn.fetch_query_params(conn)
    cwd = File.cwd!()
    req_path = conn.query_params["path"] || ""

    resolved = Path.expand(req_path, cwd)

    unless String.starts_with?(resolved, cwd) do
      json_error(conn, 403, "forbidden", "Path is outside the workspace")
    else
      if File.regular?(resolved) do
        case File.stat(resolved) do
          {:ok, %{size: size}} when size > 512_000 ->
            json_error(conn, 413, "too_large", "File exceeds 500KB limit")

          _ ->
            case File.read(resolved) do
              {:ok, content} ->
                # Check if binary — if so, don't return content
                if String.valid?(content) do
                  body =
                    Jason.encode!(%{
                      content: content,
                      path: Path.relative_to(resolved, cwd),
                      size: byte_size(content)
                    })

                  conn |> put_resp_content_type("application/json") |> send_resp(200, body)
                else
                  json_error(conn, 415, "binary_file", "Binary files cannot be previewed")
                end

              {:error, reason} ->
                json_error(conn, 500, "read_error", "Failed to read: #{inspect(reason)}")
            end
        end
      else
        json_error(conn, 404, "not_found", "File not found: #{req_path}")
      end
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Workspace endpoint not found")
  end

  # ── Private ───────────────────────────────────────────────────────────────

  # Run git commands in the given directory.
  # Both lists are empty when git is not available or the directory is not a git repo.
  defp fetch_git_info(cwd) do
    status_lines = run_git(cwd, ["status", "--short"])
    log_lines = run_git(cwd, ["log", "--oneline", "-5"])

    branch =
      case run_git(cwd, ["branch", "--show-current"]) do
        [name | _] when name != "" -> name
        _ -> nil
      end

    {status_lines, log_lines, branch}
  end

  defp detect_project_type(files) do
    file_set = MapSet.new(files)

    cond do
      MapSet.member?(file_set, "mix.exs") and MapSet.member?(file_set, "Cargo.toml") ->
        "elixir/rust"

      MapSet.member?(file_set, "mix.exs") ->
        "elixir"

      MapSet.member?(file_set, "Cargo.toml") ->
        "rust"

      MapSet.member?(file_set, "package.json") ->
        "javascript"

      MapSet.member?(file_set, "pyproject.toml") or MapSet.member?(file_set, "requirements.txt") ->
        "python"

      true ->
        "unknown"
    end
  end

  defp session_count do
    OptimalSystemAgent.Agent.SessionPersistence.list(limit: 100)
    |> length()
  rescue
    _ -> 0
  end

  defp memory_count do
    path = Path.expand("~/.osa/memory.json")

    with {:ok, json} <- File.read(path),
         {:ok, decoded} <- Jason.decode(json) do
      cond do
        is_list(decoded) -> length(decoded)
        is_map(decoded) -> map_size(decoded)
        true -> 0
      end
    else
      _ -> 0
    end
  rescue
    _ -> 0
  end

  # Get git status for a single file (M, A, D, or nil)
  defp git_file_status(cwd, relative_path) do
    case System.cmd("git", ["status", "--porcelain", relative_path],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" ->
            nil

          line ->
            case String.at(line, 0) do
              "M" ->
                "M"

              "A" ->
                "A"

              "D" ->
                "D"

              "?" ->
                "U"

              _ ->
                case String.at(line, 1) do
                  "M" -> "M"
                  "D" -> "D"
                  _ -> nil
                end
            end
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp run_git(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: false) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {_, _code} ->
        []
    end
  rescue
    # git not on PATH, or any other OS-level error
    e ->
      Logger.debug("[WorkspaceRoutes] git command failed: #{Exception.message(e)}")
      []
  end
end
