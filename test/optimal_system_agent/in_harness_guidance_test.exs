defmodule OptimalSystemAgent.InHarnessGuidanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Everything a user needs must be reachable from inside the running session.

  The one sanctioned departure is the browser hop that an account connect
  requires; nothing else may tell someone to quit OSA and run another program
  to fix the thing they are already looking at.

  This regressed silently and at scale: 29 strings across the provider, auth
  and onboarding layers instructed the user to `osa setup`, including the
  generic `Auth.Subscription.message(:not_connected, …)` that EVERY
  subscription provider shares. A user who signed in, hit an expired token and
  read the error was told to leave. Fixing the strings alone would not have
  held — the messages are written per-provider, so the next provider added
  would have reintroduced it. Hence a class guard rather than six assertions.
  """

  # Files whose user-facing strings are checked. Comments are stripped first,
  # so a `# ... osa setup ...` explanation (there are several, and they are
  # worth keeping) does not trip this.
  @sources [
    "lib/optimal_system_agent/auth/subscription.ex",
    "lib/optimal_system_agent/auth/legacy_anthropic_oauth.ex",
    "lib/optimal_system_agent/auth/providers/bedrock.ex",
    "lib/optimal_system_agent/providers/error_catalog.ex",
    "lib/optimal_system_agent/providers/anthropic.ex"
  ]

  # `osa setup` is the specific regression. The others are the same mistake
  # wearing a different hat — all of them mean "leave and run something else".
  @exit_phrases ["osa setup", "osa auth login", "mix osa.setup"]

  defp code_without_comments(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(fn line ->
      # Strip a trailing comment, but only when the `#` is outside a string —
      # approximated by requiring an even number of unescaped quotes before it,
      # which is exact for every line in these files today.
      case String.split(line, "#", parts: 2) do
        [before, _comment] ->
          if before |> String.graphemes() |> Enum.count(&(&1 == "\"")) |> rem(2) == 0,
            do: before,
            else: line

        [only] ->
          only
      end
    end)
    |> Enum.join("\n")
  end

  test "no user-facing message tells the user to leave the session" do
    offenders =
      for path <- @sources,
          File.exists?(path),
          code = code_without_comments(path),
          phrase <- @exit_phrases,
          String.contains?(code, phrase) do
        "#{path}: #{phrase}"
      end

    assert offenders == [],
           """
           These messages send the user out of the running session:

           #{Enum.join(offenders, "\n")}

           Point at an in-session command instead — /login to sign in with an
           account, /provider to add or change an API key, /model to switch
           models. The CLI still exists; it is just not the advice.
           """
  end

  test "the shared not-connected message names an in-session command" do
    # This one string is reached by every subscription provider, so it is worth
    # pinning on its own rather than relying on the sweep above.
    msg = OptimalSystemAgent.Auth.Subscription.message(:not_connected, "ChatGPT (Codex)")

    assert msg =~ "ChatGPT (Codex)"
    assert msg =~ "/login"
    refute msg =~ "osa setup"
  end

  test "every subscription provider's not-connected message is in-session" do
    # Guards the provider that gets added next: a bespoke override that
    # reintroduces shell guidance fails here even though the shared default
    # above is fine.
    for provider <- OptimalSystemAgent.Auth.Subscription.supported() do
      msg = OptimalSystemAgent.Auth.Subscription.message(:not_connected, provider)

      refute msg =~ "osa setup",
             "#{provider}'s not-connected message sends the user out to a shell: #{msg}"
    end
  end
end
