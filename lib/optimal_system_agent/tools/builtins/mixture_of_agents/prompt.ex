defmodule OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.Prompt do
  @moduledoc """
  Dynamic prompt for `mixture_of_agents`.

  References the `delegate` tool via `safe_ref/3` so a rename there
  propagates automatically.
  """

  alias OptimalSystemAgent.Tools.Builtins.MixtureOfAgents.Constants

  @spec render(keyword()) :: String.t()
  def render(_opts \\ []) do
    delegate_name =
      safe_ref(
        OptimalSystemAgent.Tools.Builtins.Delegate.Constants,
        :tool_name,
        "delegate"
      )

    """
    Fan out a query to multiple LLM providers in parallel and synthesize the best response.

    Use for critical decisions, complex analysis, or problems requiring high confidence.
    Returns a synthesized answer combining insights from all models.

    Parameters:
    - `query`     — the question or problem to send to multiple models.
    - `providers` — optional list of providers (e.g. `["anthropic", "openai", "groq"]`).
                    Defaults to all providers with a configured API key.

    Providers checked (in order): #{Enum.join(Constants.candidate_providers(), ", ")}.

    Requires at least 2 available providers. Each provider has a
    #{Constants.provider_timeout_ms()}ms timeout. Responses are synthesized
    into a single answer by the primary model.

    Related tool:
    - `#{delegate_name}` — dispatch a full task to a sub-agent rather than
      just querying multiple models.
    """
  end

  defp safe_ref(mod, fun, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
