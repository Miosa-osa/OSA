defmodule OptimalSystemAgent.Channels.HTTP.API.TuiContextRoutesTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.TuiRoutes
  alias OptimalSystemAgent.StartupContext

  @opts TuiRoutes.init([])

  defp get_context(path \\ "/context", headers \\ []) do
    Enum.reduce(headers, conn(:get, path), fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
    |> TuiRoutes.call(@opts)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /context" do
    test "returns startup context JSON" do
      conn = get_context()
      body = decode(conn)

      assert conn.status == 200
      assert is_binary(body["cwd"])
      assert body["cwd"] == body["working_dir"]
      assert is_map(body["git"])
      assert is_map(body["project"])
      assert is_map(body["session"])
      assert is_list(body["memory_hints"])
      assert is_map(body["capabilities"])
      assert is_binary(body["generated_at"])
    end

    test "uses session_id query param when present" do
      conn = get_context("/context?session_id=tui-query-session")
      body = decode(conn)

      assert body["session_id"] == "tui-query-session"
    end

    test "uses session id header when query param is absent" do
      conn = get_context("/context", [{"x-session-id", "tui-header-session"}])
      body = decode(conn)

      assert body["session_id"] == "tui-header-session"
    end
  end

  describe "StartupContext.build/1" do
    test "detects project marker files and degrades outside git" do
      tmp =
        Path.join(System.tmp_dir!(), "osa-startup-context-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "mix.exs"), "")
      File.write!(Path.join(tmp, "package.json"), "{}")
      File.mkdir_p!(Path.join(tmp, "lib"))

      context = StartupContext.build(cwd: tmp)

      assert context.cwd == tmp
      assert context.working_dir == tmp
      refute context.git.available
      assert context.git.status == []
      assert context.session.is_new
      assert "elixir" in context.project.types
      assert "node" in context.project.types
      assert %{file: "mix.exs", type: "elixir"} in context.project.files
      assert "lib" in context.project.directories

      File.rm_rf!(tmp)
    end

    test "normalizes blank session id to nil" do
      context = StartupContext.build(session_id: "  ")

      assert context.session_id == nil
    end
  end
end
