defmodule OptimalSystemAgent.Utils.Browser do
  @moduledoc """
  Best-effort "open a URL in the system browser" helper.

  Every OAuth flow in OSA (REPL `/login`, `/setup`'s Anthropic OAuth branch,
  the legacy `osa.chat` first-run) prints the authorize URL and then tries to
  auto-open it as a convenience. On a headless box (SSH session, container,
  WSL without a desktop) the opener binary (`xdg-open` on Linux, `open` on
  macOS) is frequently missing, and `System.cmd/2` RAISES `ErlangError`
  (`:enoent`) rather than returning an error tuple when the executable can't
  be found on PATH. Every call site used to invoke `System.cmd/2` directly
  and unguarded, so a first-time user on a headless machine choosing
  "Sign in with Anthropic" crashed the whole setup process with a raw
  Erlang stack trace — even though the URL had already been printed and the
  flow could keep working fine via manual copy/paste.

  This wraps the attempt so a missing/failing opener silently degrades to
  "user copies the printed link" instead of taking down onboarding.

  Opening is gated by `config :optimal_system_agent, :browser_open_enabled`
  (default `true`, set to `false` in `config/test.exs`). Without that gate a
  test that exercises `open/1` on a developer's DESKTOP machine really does
  launch their browser — which is exactly how a placeholder OAuth URL from a
  test fixture ended up popping open on a user's screen on every suite run.
  """

  @doc """
  Attempt to open `url` in the user's default browser. Always returns `:ok`,
  regardless of whether the opener binary exists, succeeds, or crashes —
  callers should already have printed the URL so this is purely a
  convenience, never a requirement for the flow to continue.

  Returns `:ok` WITHOUT spawning anything when `:browser_open_enabled` is
  `false` (test/headless/unattended runs).
  """
  @spec open(String.t()) :: :ok
  def open(url) when is_binary(url) do
    if enabled?() do
      {opener, args} = command_for(:os.type(), url)
      System.cmd(opener, args)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Whether `open/1` is allowed to actually launch a browser."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:optimal_system_agent, :browser_open_enabled, true) != false
  end

  # Split out and public (but `@doc false`) purely so the "which binary would
  # we try to exec" decision is unit-testable without depending on the host
  # OS's actual `:os.type/0`, and without needing the binary to exist.
  @doc false
  @spec command_for({atom(), atom()}, String.t()) :: {String.t(), [String.t()]}
  def command_for({:unix, :darwin}, url), do: {"open", [url]}
  def command_for({:unix, _}, url), do: {"xdg-open", [url]}
  def command_for({:win32, _}, url), do: {"cmd", ["/c", "start", url]}
  def command_for(_, url), do: {"true", [url]}
end
