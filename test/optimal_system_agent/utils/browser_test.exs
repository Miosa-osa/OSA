defmodule OptimalSystemAgent.Utils.BrowserTest do
  @moduledoc """
  Regression coverage for the "missing xdg-open crashes onboarding OAuth"
  bug: on a headless box (no desktop, SSH session), `System.cmd/2` raises
  `ErlangError` (:enoent) when the opener binary isn't on PATH. Every OAuth
  call site used to invoke `System.cmd/2` directly and unguarded, so
  `/setup` → "Sign in with Anthropic" → browser-open crashed the whole
  process instead of degrading to "copy the printed URL".
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

  describe "open/1" do
    test "returns :ok on a normal host where the opener binary exists" do
      assert Browser.open("https://example.invalid/oauth/callback?state=test") == :ok
    end

    test "returns :ok (never raises) when the opener binary is entirely absent from PATH" do
      # This is the exact real-world failure this module exists to prevent:
      # a headless box (SSH session, container, minimal WSL) with no
      # xdg-open/open on PATH at all. Emptying PATH forces System.cmd/2 to
      # hit :enoent for every opener, proving the rescue/catch in open/1
      # actually catches it end-to-end rather than just in theory.
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "")
        assert Browser.open("https://example.invalid/oauth/callback") == :ok
      after
        if original_path, do: System.put_env("PATH", original_path)
      end
    end
  end
end
