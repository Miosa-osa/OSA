defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.HelperPathTest do
  @moduledoc """
  The desktop capture helper is executed on every capture, with the user's
  privileges, and it reads the screen and injects input. These tests pin that
  a user-writable path can no longer win the lookup.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.HelperPath

  @helper "osa-screen-capture-test"

  setup do
    dir = Path.join(System.tmp_dir!(), "helperpath-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    priv = Path.join(dir, "bundled-#{@helper}")
    user = Path.join(dir, "user-#{@helper}")
    File.write!(priv, "bundled binary")
    File.write!(user, "attacker binary")

    System.delete_env("OSA_DESKTOP_HELPER_OVERRIDE")
    System.delete_env("OSA_DESKTOP_HELPER_SHA256")

    on_exit(fn ->
      System.delete_env("OSA_DESKTOP_HELPER_OVERRIDE")
      System.delete_env("OSA_DESKTOP_HELPER_SHA256")
      File.rm_rf(dir)
    end)

    {:ok, dir: dir, priv: priv, user: user}
  end

  describe "resolve/4" do
    test "prefers the bundled binary over a user-writable one", %{priv: priv, user: user} do
      # The old order tried `~/.osa/helpers` / `%USERPROFILE%\.osa\helpers`
      # FIRST, so anything that could write a file as the user got code
      # execution on the next desktop capture.
      assert {:ok, priv} == HelperPath.resolve(@helper, priv, user, "docs/x.md")
    end

    test "a user-path binary is never spawned when the bundle is missing", %{
      dir: dir,
      user: user
    } do
      missing_priv = Path.join(dir, "absent")

      assert {:error, {:missing_helper, msg}} =
               HelperPath.resolve(@helper, missing_priv, user, "docs/x.md")

      assert msg =~ "not found"
      assert msg =~ "NOT used unless pinned"
    end
  end

  describe "pinned override" do
    test "runs an override whose hash matches", %{dir: dir, priv: priv, user: user} do
      override = Path.join(dir, "override")
      File.write!(override, "explicitly trusted binary")

      System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", override)
      System.put_env("OSA_DESKTOP_HELPER_SHA256", HelperPath.sha256_file(override))

      assert {:ok, override} == HelperPath.resolve(@helper, priv, user, "docs/x.md")
    end

    test "refuses an override with no pin", %{priv: priv, user: user} do
      System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", user)

      assert {:error, {:untrusted_helper, msg}} =
               HelperPath.resolve(@helper, priv, user, "docs/x.md")

      assert msg =~ "SHA256 is not"
    end

    test "refuses an override whose contents changed after pinning", %{
      dir: dir,
      priv: priv,
      user: user
    } do
      override = Path.join(dir, "override2")
      File.write!(override, "original")
      pin = HelperPath.sha256_file(override)

      File.write!(override, "swapped out under us")

      System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", override)
      System.put_env("OSA_DESKTOP_HELPER_SHA256", pin)

      assert {:error, {:untrusted_helper, msg}} =
               HelperPath.resolve(@helper, priv, user, "docs/x.md")

      assert msg =~ "does not match"
    end

    test "does not fall back to the bundle when the pin fails", %{priv: priv, user: user} do
      System.put_env("OSA_DESKTOP_HELPER_OVERRIDE", user)
      System.put_env("OSA_DESKTOP_HELPER_SHA256", String.duplicate("0", 64))

      refute match?({:ok, ^priv}, HelperPath.resolve(@helper, priv, user, "docs/x.md"))
    end
  end
end
