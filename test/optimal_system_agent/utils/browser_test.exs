defmodule OptimalSystemAgent.Utils.BrowserTest do
  @moduledoc """
  Regression coverage for the "missing xdg-open crashes onboarding browser hand-off"
  bug: on a headless box (no desktop, SSH session), `System.cmd/2` raises
  `ErlangError` (:enoent) when the opener binary isn't on PATH. Every browser
  call site used to invoke `System.cmd/2` directly and unguarded, so a
  browser-open step in `/setup` crashed the whole process instead of
  degrading to "copy the printed URL".
  """
  # Mutates PATH for the process — must not run concurrently with anything
  # else that shells out.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Utils.Browser

  describe "command_for/2 (pure OS -> opener mapping)" do
    test "macOS uses `open`" do
      assert Browser.command_for({:unix, :darwin}, "https://x.test") ==
               {"open", ["https://x.test"]}
    end

    test "other unix (Linux/BSD) uses `xdg-open`" do
      assert Browser.command_for({:unix, :linux}, "https://x.test") ==
               {"xdg-open", ["https://x.test"]}
    end

    test "Windows uses `cmd /c start`" do
      assert Browser.command_for({:win32, :nt}, "https://x.test") ==
               {"cmd", ["/c", "start", "https://x.test"]}
    end
  end

  describe "open/1 — the suite must never launch a real browser" do
    test "is disabled in the test env, so nothing is ever spawned" do
      # THE REGRESSION. This test previously called Browser.open/1 with a
      # placeholder URL under the real PATH, which on a desktop machine
      # (real $DISPLAY) made `xdg-open` genuinely open a browser tab to
      # `https://example.invalid/oauth/callback?state=test` on EVERY suite run.
      # The user experienced that as OSA repeatedly demanding sign-in against an
      # RFC-2606 reserved domain that can never resolve.
      refute Browser.enabled?()
      assert Browser.open("https://osa.test/never-opened") == :ok
    end

    test "returns :ok (never raises) when the opener binary is entirely absent from PATH" do
      # This is the exact real-world failure this module exists to prevent:
      # a headless box (SSH session, container, minimal WSL) with no
      # xdg-open/open on PATH at all. Emptying PATH forces System.cmd/2 to
      # hit :enoent for every opener, proving the rescue/catch in open/1
      # actually catches it end-to-end rather than just in theory. The gate is
      # enabled here so the real System.cmd/2 path is genuinely exercised.
      original_path = System.get_env("PATH")

      with_browser_enabled(fn ->
        try do
          System.put_env("PATH", "")
          assert Browser.open("https://osa.test/headless") == :ok
        after
          if original_path, do: System.put_env("PATH", original_path)
        end
      end)
    end

    test "returns :ok when an opener DOES exist, without opening anything real" do
      # PATH is pointed at a temp dir holding no-op stubs named after every
      # opener, so the System.cmd/2 success path runs for real while nothing
      # is displayed to the developer.
      stub_dir =
        Path.join(System.tmp_dir!(), "osa-browser-stub-#{System.unique_integer([:positive])}")

      File.mkdir_p!(stub_dir)

      for name <- ["xdg-open", "open", "cmd", "true"] do
        path = Path.join(stub_dir, name)
        File.write!(path, "#!/bin/sh\nexit 0\n")
        File.chmod!(path, 0o755)
      end

      original_path = System.get_env("PATH")

      on_exit(fn ->
        File.rm_rf(stub_dir)
        if original_path, do: System.put_env("PATH", original_path)
      end)

      with_browser_enabled(fn ->
        System.put_env("PATH", stub_dir)
        assert Browser.open("https://osa.test/stubbed") == :ok
      end)
    end
  end

  defp with_browser_enabled(fun) do
    prev = Application.get_env(:optimal_system_agent, :browser_open_enabled)
    Application.put_env(:optimal_system_agent, :browser_open_enabled, true)

    try do
      fun.()
    after
      case prev do
        nil -> Application.delete_env(:optimal_system_agent, :browser_open_enabled)
        v -> Application.put_env(:optimal_system_agent, :browser_open_enabled, v)
      end
    end
  end
end
