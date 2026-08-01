defmodule OptimalSystemAgent.Agent.Loop.ContextWindow do
  @moduledoc """
  One honest answer to "how big is this session's context window?".

  Every consumer that budgets, meters, or COMPACTS against the context window
  must get its denominator from here, so the status bar, the proactive
  compaction threshold, and `Agent.Compactor` can never disagree.

  ## Why this exists

  `Agent.Compactor` used to read a flat
  `Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)`
  and was never handed the real per-model window at any of its call sites. On a
  1M-token model that meant a full LLM summarization pass fired at roughly 11%
  of the actual window, repeatedly, while the status bar (which had already been
  fixed to use the real window) correctly reported 11%. Every one of those
  compactions permanently destroyed conversation fidelity.

  ## Honest, not confident

  `resolve/1` returns `{:ok, tokens} | :unknown` and is built on
  `Providers.Registry.effective_context_window_info/2` — the variant that
  admits ignorance — NOT `effective_context_window/2`, which silently
  substitutes the 128k config default for any model nobody has heard of.

  Callers must handle `:unknown` deliberately. For compaction the policy is to
  DEFER (see `Agent.Compactor.maybe_compact/4`): a guessed denominator is what
  caused the bug, and an unnecessary compaction is unrecoverable while a
  deferred one is corrected by the provider's own context-length error.
  """

  alias OptimalSystemAgent.Providers.Registry

  @doc """
  Resolve the effective context window for an agent-loop state map.

  Reads `:model` and `:provider` from the state. A state with no usable model
  resolves to `:unknown`; so does a model the registry cannot vouch for.

  Never raises, and never falls back to a hardcoded number.
  """
  @spec resolve(map() | nil) :: {:ok, pos_integer()} | :unknown
  def resolve(state) when is_map(state) do
    case Map.get(state, :model) do
      model when is_binary(model) and model != "" ->
        case normalize_provider(Map.get(state, :provider)) do
          nil -> normalize(Registry.context_window_info(model))
          provider -> normalize(Registry.effective_context_window_info(model, provider))
        end

      _ ->
        :unknown
    end
  rescue
    _ -> :unknown
  end

  def resolve(_), do: :unknown

  defp normalize({:ok, n}) when is_integer(n) and n > 0, do: {:ok, n}
  defp normalize(_), do: :unknown

  defp normalize_provider(p) when is_atom(p) and not is_nil(p), do: p

  defp normalize_provider(p) when is_binary(p) and p != "" do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end

  defp normalize_provider(_), do: nil
end
