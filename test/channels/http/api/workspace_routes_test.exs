defmodule OptimalSystemAgent.Channels.HTTP.API.WorkspaceRoutesTest do
  @moduledoc """
  Tests for GET /workspace (WorkspaceRoutes).

  The endpoint returns cwd, git_status, git_log, directories, and files.
  Git fields degrade gracefully to empty lists when git is unavailable
  or the working directory is not a repository.
  """
  use ExUnit.Case, async: true
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.WorkspaceRoutes

  @opts WorkspaceRoutes.init([])

  defp get_workspace do
    conn(:get, "/")
    |> WorkspaceRoutes.call(@opts)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # ── Response structure ───────────────────────────────────────────────────────

  describe "GET / — response structure" do
    test "returns 200" do
      conn = get_workspace()
      assert conn.status == 200
    end

    test "response has content-type application/json" do
      conn = get_workspace()
      [ct | _] = get_resp_header(conn, "content-type")
      assert String.starts_with?(ct, "application/json")
    end

    test "response body contains all expected keys" do
      conn = get_workspace()
      body = decode(conn)

      assert Map.has_key?(body, "cwd")
      assert Map.has_key?(body, "project_name")
      assert Map.has_key?(body, "project_type")
      assert Map.has_key?(body, "git_status")
      assert Map.has_key?(body, "git_log")
      assert Map.has_key?(body, "git_branch")
      assert Map.has_key?(body, "git_dirty")
      assert Map.has_key?(body, "directories")
      assert Map.has_key?(body, "files")
      assert Map.has_key?(body, "session_count")
      assert Map.has_key?(body, "memory_count")
    end

    test "cwd is a non-empty string" do
      conn = get_workspace()
      body = decode(conn)

      assert is_binary(body["cwd"])
      assert String.length(body["cwd"]) > 0
    end

    test "git_status is a list" do
      conn = get_workspace()
      body = decode(conn)
      assert is_list(body["git_status"])
    end

    test "git_log is a list" do
      conn = get_workspace()
      body = decode(conn)
      assert is_list(body["git_log"])
    end

    test "directories is a list" do
      conn = get_workspace()
      body = decode(conn)
      assert is_list(body["directories"])
    end

    test "files is a list" do
      conn = get_workspace()
      body = decode(conn)
      assert is_list(body["files"])
    end

    test "all entries in directories are strings" do
      conn = get_workspace()
      body = decode(conn)
      assert Enum.all?(body["directories"], &is_binary/1)
    end

    test "all entries in files are strings" do
      conn = get_workspace()
      body = decode(conn)
      assert Enum.all?(body["files"], &is_binary/1)
    end

    test "all entries in git_status are strings" do
      conn = get_workspace()
      body = decode(conn)
      assert Enum.all?(body["git_status"], &is_binary/1)
    end

    test "all entries in git_log are strings" do
      conn = get_workspace()
      body = decode(conn)
      assert Enum.all?(body["git_log"], &is_binary/1)
    end
  end

  # ── Directory listing ────────────────────────────────────────────────────────

  describe "GET / — directory listing" do
    test "directories are sorted alphabetically" do
      conn = get_workspace()
      body = decode(conn)
      dirs = body["directories"]
      assert dirs == Enum.sort(dirs)
    end

    test "files are sorted alphabetically" do
      conn = get_workspace()
      body = decode(conn)
      files = body["files"]
      assert files == Enum.sort(files)
    end

    test "cwd matches the actual working directory" do
      conn = get_workspace()
      body = decode(conn)
      {:ok, actual_cwd} = File.cwd()
      assert body["cwd"] == actual_cwd
    end

    test "project_name matches cwd basename" do
      conn = get_workspace()
      body = decode(conn)
      {:ok, actual_cwd} = File.cwd()
      assert body["project_name"] == Path.basename(actual_cwd)
    end

    test "project metadata has stable primitive types" do
      conn = get_workspace()
      body = decode(conn)

      assert is_binary(body["project_type"])
      assert is_boolean(body["git_dirty"])
      assert is_integer(body["session_count"])
      assert is_integer(body["memory_count"])
    end

    test "directories and files together account for entries in cwd" do
      conn = get_workspace()
      body = decode(conn)
      {:ok, actual_cwd} = File.cwd()
      actual_entries = File.ls!(actual_cwd) |> Enum.sort()
      returned_entries = (body["directories"] ++ body["files"]) |> Enum.sort()
      assert returned_entries == actual_entries
    end
  end

  # ── Git fields ───────────────────────────────────────────────────────────────

  describe "GET / — git fields" do
    test "git_log entries have at most 5 items (git log -5)" do
      conn = get_workspace()
      body = decode(conn)
      assert length(body["git_log"]) <= 5
    end

    test "git_status entries do not contain empty strings" do
      conn = get_workspace()
      body = decode(conn)
      refute Enum.any?(body["git_status"], fn s -> s == "" end)
    end

    test "git_log entries do not contain empty strings" do
      conn = get_workspace()
      body = decode(conn)
      refute Enum.any?(body["git_log"], fn s -> s == "" end)
    end
  end

  # ── Unknown paths ────────────────────────────────────────────────────────────

  describe "unknown paths" do
    test "returns 404 for unknown sub-paths" do
      conn =
        conn(:get, "/nonexistent")
        |> WorkspaceRoutes.call(@opts)

      assert conn.status == 404
    end

    test "404 body is valid JSON with error field" do
      conn =
        conn(:get, "/nonexistent")
        |> WorkspaceRoutes.call(@opts)

      body = decode(conn)
      assert body["error"] == "not_found"
    end
  end
end
