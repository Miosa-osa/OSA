defmodule OptimalSystemAgent.Security.LoginPreflightTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.LoginPreflight

  @no_artifact "login preflight failed: no session artifact (cookies/authorization/storage_state)"

  test "check with Authorization Bearer token is authenticated" do
    assert {:ok, :authenticated} =
             LoginPreflight.check(%{headers: %{"Authorization" => "Bearer tok-abc"}})

    assert {:ok, :authenticated} =
             LoginPreflight.check(%{"headers" => %{"authorization" => "Bearer tok-abc"}})
  end

  test "check with cookie sid=abc is authenticated" do
    assert {:ok, :authenticated} = LoginPreflight.check(%{cookies: "sid=abc"})
    assert {:ok, :authenticated} = LoginPreflight.check(%{"cookies" => "sid=abc"})
  end

  test "check %{} errors" do
    assert {:error, @no_artifact} = LoginPreflight.check(%{})
  end

  test "required_for :idor is true, :sqli is false" do
    assert LoginPreflight.required_for?(:idor)
    refute LoginPreflight.required_for?(:sqli)
  end

  test "assert_for :sqli with empty session is :ok" do
    assert :ok = LoginPreflight.assert_for(:sqli, %{})
  end

  test "assert_for :idor with empty session errors" do
    assert {:error, @no_artifact} = LoginPreflight.assert_for(:idor, %{})
  end

  test "storage_state tmp json file with cookies array works" do
    path =
      Path.join(
        System.tmp_dir!(),
        "osa-login-preflight-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      Jason.encode!(%{
        "cookies" => [%{"name" => "sid", "value" => "abc", "domain" => "example.test"}]
      })
    )

    try do
      assert {:ok, :authenticated} = LoginPreflight.check(%{storage_state: path})
    after
      File.rm(path)
    end
  end
end
