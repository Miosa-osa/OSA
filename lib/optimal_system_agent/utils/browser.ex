defmodule OptimalSystemAgent.Utils.Browser do
  @moduledoc """
  Best-effort "open a URL in the system browser" helper.

  Any browser hand-off in OSA should print the URL first and then try to
  auto-open it as a convenience. On a headless box (SSH session, container,
  WSL without a desktop) the opener binary (`xdg-open` on Linux, `open` on
  macOS) is frequently missing, and `System.cmd/2` RAISES `ErlangError`
  (`:enoent`) rather than returning an error tuple when the executable can't
  be found on PATH. Call sites used to invoke `System.cmd/2` directly and
  unguarded, so a first-time user on a headless machine picking a
  browser-based setup step crashed the whole setup process with a raw Erlang
  stack trace — even though the URL had already been printed and the flow
  could keep working fine via manual copy/paste.

  > OSA currently has no in-app browser hand-off: the only one that existed was
  > the Anthropic subscription sign-in, which was removed (see
  > `OptimalSystemAgent.Auth.LegacyAnthropicOAuth`). This helper is kept as the
  > safe entry point for the next one.

  This wraps the attempt so a missing/failing opener silently degrades to
  "user copies the printed link" instead of taking down onboarding.

  Opening is gated by `config :optimal_system_agent, :browser_open_enabled`
  (default `true`, set to `false` in `config/test.exs`). Without that gate a
  test that exercises `open/1` on a developer's DESKTOP machine really does
  launch their browser — which is exactly how a placeholder URL from a test
  fixture ended up popping open on a user's screen on every suite run.
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
      System.cmd(opener, args, env: OptimalSystemAgent.OS.Env.cmd_env())
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
  # NOT `cmd /c start <url>`. `start` parses its first quoted argument as the
  # WINDOW TITLE, so the URL is consumed as a title and `start` then opens a
  # window with no target — the user sees a stray Explorer/console window at
  # the working directory instead of the sign-in page, and the OAuth flow they
  # were sent to never loads. `&` in a URL (device-flow codes routinely carry
  # query parameters) is also a `cmd` command separator, which truncates the
  # URL even once the title slot is filled.
  #
  # `rundll32 url.dll,FileProtocolHandler` hands the URL to the default
  # protocol handler with no shell in the path at all, so neither the title
  # slot nor `&` can bite. It ships with every supported Windows version.
  def command_for({:win32, _}, url), do: {"rundll32", ["url.dll,FileProtocolHandler", url]}
  def command_for(_, url), do: {"true", [url]}
end
