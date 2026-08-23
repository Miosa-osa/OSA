defmodule OptimalSystemAgent.Security.LoginSessionTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Security.LoginSession

  defp sid, do: "login-session-#{System.unique_integer([:positive])}"

  test "put cookie string, cookie_header returns it" do
    sid = sid()
    assert {:ok, rec} = LoginSession.put(sid, %{cookies: "sid=abc"})
    assert rec.cookies == "sid=abc"
    assert %DateTime{} = rec.updated_at
    assert {:ok, "sid=abc"} = LoginSession.cookie_header(sid)
    assert {:ok, ^rec} = LoginSession.get(sid)
  end

  test "put Playwright cookies list, header joined" do
    sid = sid()

    cookies = [
      %{"name" => "a", "value" => "b", "domain" => "example.test", "path" => "/"},
      %{"name" => "c", "value" => "d", "httpOnly" => true, "secure" => true}
    ]

    assert {:ok, rec} = LoginSession.put(sid, %{cookies: cookies})
    assert rec.cookies == "a=b; c=d"
    assert {:ok, "a=b; c=d"} = LoginSession.cookie_header(sid)
  end

  test "put storage_state tmp json, LoginPreflight.check(artifact_map) is authenticated" do
    sid = sid()

    path =
      Path.join(
        System.tmp_dir!(),
        "osa-login-session-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      Jason.encode!(%{
        "cookies" => [%{"name" => "sid", "value" => "abc", "domain" => "example.test"}],
        "origins" => []
      })
    )

    try do
      assert {:ok, rec} = LoginSession.put(sid, %{storage_state: path})
      assert is_map(rec.storage_state)
      artifacts = LoginSession.artifact_map(sid)

      if Code.ensure_loaded?(OptimalSystemAgent.Security.LoginPreflight) and
           function_exported?(OptimalSystemAgent.Security.LoginPreflight, :check, 1) do
        assert {:ok, :authenticated} =
                 OptimalSystemAgent.Security.LoginPreflight.check(artifacts)
      else
        assert artifacts.storage_state["cookies"] != []
      end
    after
      File.rm(path)
    end
  end

  test "assert_ready :idor without session errors" do
    assert {:error, reason} = LoginSession.assert_ready(sid(), :idor)
    assert is_binary(reason)
    assert reason != ""
  end

  test "assert_ready :sqli without session is :ok" do
    assert :ok = LoginSession.assert_ready(sid(), :sqli)
  end

  test "put empty map errors" do
    assert {:error, reason} = LoginSession.put(sid(), %{})
    assert is_binary(reason)
    assert reason != ""
  end
end
