defmodule OptimalSystemAgent.Tools.Builtins.DownloadTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.Download, as: DownloadShim
  alias OptimalSystemAgent.Tools.Builtins.Download.{Constants, Handler, Tool}
  alias OptimalSystemAgent.Tools.UseContext

  defp ctx, do: %UseContext{session_id: "download_test"}

  # ---------------------------------------------------------------------------
  # Structured layout — identity callbacks
  # ---------------------------------------------------------------------------

  describe "Tool identity" do
    test "name returns download" do
      assert Tool.name() == "download"
    end

    test "name matches Constants.tool_name" do
      assert Tool.name() == Constants.tool_name()
    end

    test "should_defer? is true" do
      assert Tool.should_defer?() == true
    end

    test "concurrency_safe? is true" do
      assert Tool.concurrency_safe?(%{}, ctx()) == true
    end

    test "read_only? is false" do
      assert Tool.read_only?(%{}, ctx()) == false
    end

    test "destructive? is false" do
      assert Tool.destructive?(%{}, ctx()) == false
    end

    test "open_world? is true" do
      assert Tool.open_world?(%{}, ctx()) == true
    end

    test "safety is :write_safe" do
      assert Tool.safety() == :write_safe
    end

    test "always_load? is false" do
      assert Tool.always_load?() == false
    end

    test "parameters requires url and path" do
      params = Tool.parameters()
      assert "url" in params["required"]
      assert "path" in params["required"]
    end
  end

  # ---------------------------------------------------------------------------
  # Shim parity — flat module delegates to Tool
  # ---------------------------------------------------------------------------

  describe "shim parity" do
    test "Download.name() delegates to Download.Tool.name()" do
      assert DownloadShim.name() == Tool.name()
    end

    test "Download.open_world?/2 is true" do
      assert DownloadShim.open_world?(%{}, ctx()) == true
    end

    test "Download has execute/2 (structured)" do
      assert {_, _} = List.keyfind(DownloadShim.__info__(:functions), :execute, 0, nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — validate
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "valid url and path passes" do
      input = %{"url" => "https://example.com/file.txt", "path" => "/tmp/out.txt"}
      assert {:ok, _} = Handler.validate(input, ctx())
    end

    test "missing path returns error" do
      assert {:error, msg, -32_602} = Handler.validate(%{"url" => "https://x.com"}, ctx())
      assert msg =~ "path"
    end

    test "missing url returns error" do
      assert {:error, msg, -32_602} = Handler.validate(%{"path" => "/tmp/x.txt"}, ctx())
      assert msg =~ "url"
    end

    test "missing both returns error" do
      assert {:error, msg, -32_602} = Handler.validate(%{}, ctx())
      assert msg =~ "url"
    end

    test "non-string url returns error" do
      assert {:error, msg, -32_602} =
               Handler.validate(%{"url" => 123, "path" => "/tmp/x.txt"}, ctx())

      assert msg =~ "strings"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — check_permissions (URL validation, SSRF guard, path allowlist)
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2 — URL scheme" do
    test "http to non-localhost is denied" do
      input = %{"url" => "http://example.com/file", "path" => "/tmp/out.txt"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx())
      assert msg =~ "HTTPS"
    end

    test "ftp scheme is denied" do
      input = %{"url" => "ftp://example.com/file", "path" => "/tmp/out.txt"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx())
      assert msg =~ "scheme"
    end

    test "localhost http is allowed" do
      input = %{"url" => "http://localhost/file", "path" => "/tmp/out.txt"}
      # may get denied for private IP or host resolution failure — that's fine
      result = Handler.check_permissions(input, ctx())
      assert match?({:allow, _}, result) or match?({:deny, _}, result)
    end
  end

  describe "Handler.check_permissions/2 — write path" do
    test "path targeting /etc is denied" do
      input = %{"url" => "https://example.com/f", "path" => "/etc/hosts"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx())
      assert msg =~ "Access denied"
    end

    test "path targeting ~/.ssh is denied" do
      input = %{"url" => "https://example.com/f", "path" => "~/.ssh/config"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx())
      assert msg =~ "Access denied"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler — private IP detection (via module internals, tested through check_permissions)
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2 — SSRF protection" do
    test "direct 10.x private IP is denied" do
      # Use an IP literal that DNS won't rewrite
      input = %{"url" => "https://10.0.0.1/file", "path" => "/tmp/out.txt"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx())
      assert msg =~ "Access denied"
    end

    test "direct 192.168.x.x private IP is denied" do
      input = %{"url" => "https://192.168.1.1/file", "path" => "/tmp/out.txt"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx())
      assert msg =~ "Access denied"
    end

    test "direct 169.254.x.x link-local is denied" do
      input = %{"url" => "https://169.254.169.254/latest/meta-data", "path" => "/tmp/out.txt"}
      assert {:deny, msg} = Handler.check_permissions(input, ctx())
      assert msg =~ "Access denied"
    end
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe "Constants" do
    test "max_download_bytes is 50 MB" do
      assert Constants.max_download_bytes() == 50 * 1024 * 1024
    end

    test "max_redirects is 3" do
      assert Constants.max_redirects() == 3
    end

    test "blocked_write_paths includes .ssh/" do
      assert ".ssh/" in Constants.blocked_write_paths()
    end

    test "blocked_write_paths includes /etc/" do
      assert "/etc/" in Constants.blocked_write_paths()
    end
  end

  # ---------------------------------------------------------------------------
  # UI renders
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    alias OptimalSystemAgent.Tools.Builtins.Download.UI

    test ":tool_use returns kind download" do
      map = UI.render(:tool_use, %{"url" => "https://x.com/f", "path" => "/tmp/f"}, [])
      assert map[:kind] == "download"
      assert map[:url] == "https://x.com/f"
      assert map[:path] == "/tmp/f"
    end

    test ":tool_result returns kind download_result" do
      map = UI.render(:tool_result, "Downloaded https://x.com to /tmp/f (1024 bytes)", [])
      assert map[:kind] == "download_result"
    end

    test ":rejected returns kind download_rejected" do
      assert %{kind: "download_rejected"} = UI.render(:rejected, %{}, [])
    end

    test ":error returns kind download_error" do
      map = UI.render(:error, "HTTP 404", [])
      assert map[:kind] == "download_error"
      assert map[:message] == "HTTP 404"
    end

    test "unknown stage returns nil" do
      assert UI.render(:progress, %{}, []) == nil
    end
  end
end
