defmodule OptimalSystemAgent.Security.AllowRulePrefixBoundaryTest do
  @moduledoc """
  An `allow` rule with a `prefix:*` content must only match at a real token
  boundary. A bare `String.starts_with?/2` lets a rule scoped to one path or
  host silently pre-approve an unrelated sibling:

      file_write(/home/u/safe:*)  →  /home/u/safe-backup-of-everything
      WebFetch(https://example.com:*) → https://example.com.evil.tld

  The two sibling matchers in `Permissions` already got this right
  (`match_shell_rule?/2` requires a space, the workspace-scope check requires
  a `/`); the generic matcher did not.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Permissions
  alias OptimalSystemAgent.Settings

  @flag_file Path.join(System.tmp_dir!(), "osa-allow-boundary-settings.json")

  setup do
    legacy = Application.get_env(:optimal_system_agent, :permissions_file)
    if is_binary(legacy), do: File.rm(legacy)
    prior_flag = Application.get_env(:optimal_system_agent, :settings_flag_path)

    on_exit(fn ->
      case prior_flag do
        nil -> Application.delete_env(:optimal_system_agent, :settings_flag_path)
        path -> Application.put_env(:optimal_system_agent, :settings_flag_path, path)
      end

      File.rm(@flag_file)
      if is_binary(legacy), do: File.rm(legacy)
      Settings.reset_cache()
    end)

    :ok
  end

  defp allow(rules) do
    File.write!(@flag_file, Jason.encode!(%{"permissions" => %{"allow" => rules}}))
    Application.put_env(:optimal_system_agent, :settings_flag_path, @flag_file)
    Settings.reset_cache()
  end

  describe "path prefix rules" do
    setup do
      allow(["Write(/home/u/safe:*)"])
      :ok
    end

    test "the rule itself and paths under it are allowed" do
      assert Permissions.check("file_write", %{"path" => "/home/u/safe"}) == :allow
      assert Permissions.check("file_write", %{"path" => "/home/u/safe/notes.txt"}) == :allow
      assert Permissions.check("file_write", %{"path" => "/home/u/safe/deep/a.txt"}) == :allow
    end

    test "a sibling path sharing the textual prefix is NOT allowed" do
      assert Permissions.check("file_write", %{"path" => "/home/u/safe-backup-of-everything"}) ==
               :ask

      assert Permissions.check("file_write", %{"path" => "/home/u/safexyz/pwn"}) == :ask
      assert Permissions.check("file_write", %{"path" => "/home/u/safe.bak"}) == :ask
    end
  end

  describe "host prefix rules" do
    setup do
      allow(["WebFetch(https://example.com:*)"])
      :ok
    end

    test "the host itself and paths under it are allowed" do
      assert Permissions.check("web_fetch", %{"url" => "https://example.com"}) == :allow
      assert Permissions.check("web_fetch", %{"url" => "https://example.com/docs"}) == :allow
      assert Permissions.check("web_fetch", %{"url" => "https://example.com/a/b?c=d"}) == :allow
    end

    test "a look-alike host is NOT allowed" do
      assert Permissions.check("web_fetch", %{"url" => "https://example.com.evil.tld"}) == :ask
      assert Permissions.check("web_fetch", %{"url" => "https://example.com.evil.tld/x"}) == :ask
      assert Permissions.check("web_fetch", %{"url" => "https://example.commerce.io"}) == :ask
      assert Permissions.check("web_fetch", %{"url" => "https://example.com@evil.tld/"}) == :ask
    end

    test "a bare-host rule still covers its own subpaths but not a suffixed host" do
      allow(["WebFetch(https://example.com/api:*)"])
      assert Permissions.check("web_fetch", %{"url" => "https://example.com/api"}) == :allow
      assert Permissions.check("web_fetch", %{"url" => "https://example.com/api/v1"}) == :allow
      assert Permissions.check("web_fetch", %{"url" => "https://example.com/apikeys"}) == :ask
    end
  end
end
