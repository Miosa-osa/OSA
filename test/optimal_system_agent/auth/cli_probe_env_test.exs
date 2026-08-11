defmodule OptimalSystemAgent.Auth.CliProbeEnvTest do
  @moduledoc """
  Both CLI-backed providers exist to answer one question: "is the USER signed
  in to this tool?" A credential inherited from the surrounding environment
  changes the answer to "is SOMEBODY signed in", and the surface still reports
  it as the user's own account.

  `ClaudeCli` already nulled the Anthropic variables, with a comment about
  silently billing the user per-token through a provider they chose precisely
  because it does not. `CopilotCli` passed only `NO_COLOR`, so a `GITHUB_TOKEN`
  from a workspace `.env`, a CI runner, or a `gh auth` shell export was visible
  to the `copilot` binary it probes — and `verified?/0` could report a sign-in
  belonging to a token the workspace supplied.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Auth.Providers.ClaudeCli
  alias OptimalSystemAgent.Auth.Providers.CopilotCli

  defp nulled(env) do
    for {k, nil} <- env, do: k
  end

  describe "CopilotCli probes the user's own sign-in" do
    test "every inheritable GitHub credential is nulled" do
      nulls = nulled(CopilotCli.probe_env())

      for var <- ~w(GITHUB_TOKEN GH_TOKEN GITHUB_ENTERPRISE_TOKEN GH_ENTERPRISE_TOKEN) do
        assert var in nulls,
               "#{var} inherited from the workspace makes the probe answer about " <>
                 "someone else's account while OSA reports it as the user's"
      end
    end

    test "GH_HOST is nulled too — a redirected probe answers about a different SERVER" do
      assert "GH_HOST" in nulled(CopilotCli.probe_env())
    end

    test "no credential is passed POSITIVELY into the subprocess" do
      # Nulling is the only correct action here. Forwarding a value — any
      # value — would be choosing an account on the user's behalf.
      for {_k, v} <- CopilotCli.probe_env(), is_binary(v) do
        refute String.starts_with?(v, "gh"), "no token may be handed to the probe"
      end
    end

    test "NO_COLOR is kept so the output stays parseable" do
      assert {"NO_COLOR", "1"} in CopilotCli.probe_env()
    end
  end

  describe "ClaudeCli keeps the discipline it already had" do
    test "the Anthropic credential variables are nulled" do
      nulls = nulled(ClaudeCli.probe_env())

      for var <- ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL) do
        assert var in nulls
      end
    end
  end

  describe "the two providers agree" do
    test "neither leaves its own credential variables inheritable" do
      # The defect was that one of them had this right and the other did not,
      # for the same class of problem. This test fails if they drift again.
      for {module, vars} <- [
            {CopilotCli, ~w(GITHUB_TOKEN GH_TOKEN)},
            {ClaudeCli, ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN)}
          ] do
        nulls = nulled(module.probe_env())
        for var <- vars, do: assert(var in nulls, "#{inspect(module)} leaks #{var}")
      end
    end
  end
end
