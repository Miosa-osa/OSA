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
        - directories : top-level directory names in cwd
        - files       : top-level regular file names in cwd
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / ─────────────────────────────────────────────────────────────────

  get "/" do
    cwd = workspace_cwd(conn)

    {git_status, git_log} = fetch_git_info(cwd)

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
        git_status: git_status,
        git_log: git_log,
        directories: Enum.sort(dirs),
        files: Enum.sort(files)
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /ls?path=<dir> ─────────────────────────────────────────────────────
  # Browse any directory relative to cwd. Used by the FileTree component.

  get "/ls" do
    conn = Plug.Conn.fetch_query_params(conn)
    cwd = workspace_cwd(conn)
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
    cwd = workspace_cwd(conn)
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

  # ── Workspace trust (CC parity: TrustDialog; WS15 deferred endpoints) ─────
  #
  #   GET  /trust?path=<dir> → full trust status for the TUI trust dialog
  #   POST /trust/accept     → accept trust for {"path": <dir>} (default cwd)

  get "/trust" do
    conn = Plug.Conn.fetch_query_params(conn)
    path = conn.query_params["path"] || OptimalSystemAgent.Workspace.Cwd.get()
    status = OptimalSystemAgent.Workspace.Trust.status(path)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(status))
  end

  post "/trust/accept" do
    path =
      case conn.body_params do
        %{"path" => p} when is_binary(p) and p != "" -> p
        _ -> OptimalSystemAgent.Workspace.Cwd.get()
      end

    :ok = OptimalSystemAgent.Workspace.Trust.accept(path)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(OptimalSystemAgent.Workspace.Trust.status(path)))
  end

  # ── GET /identity ─────────────────────────────────────────────────────────
  # Git-root-aware workspace identity for the TUI status bar / terminal title /
  # welcome banner, so the label reflects the directory the agent actually
  # operates in (not a raw path basename). Optional ?working_dir= scopes it.
  get "/identity" do
    cwd = workspace_cwd(conn)
    identity = OptimalSystemAgent.Workspace.Cwd.identity(cwd)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(identity))
  end

  match _ do
    json_error(conn, 404, "not_found", "Workspace endpoint not found")
  end

  # ── Private ───────────────────────────────────────────────────────────────

  # Resolve the workspace root for a request: an explicit ?working_dir= wins
  # (session-scoped), else the single cwd source of truth (the user's launch
  # dir), never a raw File.cwd!() that points at the OSA source tree.
  defp workspace_cwd(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.query_params["working_dir"] do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> OptimalSystemAgent.Workspace.Cwd.get()
    end
  end

  # Run git commands in the given directory. Returns {status_lines, log_lines}.
  # Both lists are empty when git is not available or the directory is not a git repo.
  defp fetch_git_info(cwd) do
    status_lines = run_git(cwd, ["status", "--short"])
    log_lines = run_git(cwd, ["log", "--oneline", "-5"])
    {status_lines, log_lines}
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
