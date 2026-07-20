defmodule OptimalSystemAgent.Agents.Config do
  @moduledoc """
  User-facing per-agent customization: model + tier overrides read from the
  settings cascade so users can retarget which model runs which agent (and at
  what tier) WITHOUT hand-editing each agent's `.md` frontmatter.

  Overrides live under the `agent_overrides` settings key (settings.json):

      "agent_overrides": {
        "code-reviewer": { "model": "glm-5.2:cloud", "tier": "elite" },
        "debugger":      { "model": "minimax-m3:cloud" }
      }

  Resolution precedence (high -> low), applied by the spawn paths:

      explicit per-call arg  >  settings override (here)  >  agent .md frontmatter  >  tier default

  So a settings override retargets an agent globally, an agent's own `.md`
  `model:`/`tier:` is the shipped default, and a one-off `delegate` call arg
  still wins for that single dispatch.
  """

  alias OptimalSystemAgent.Settings

  @settings_key "agent_overrides"

  @doc "Per-agent model override from settings, or nil when unset."
  @spec model_override(String.t() | nil) :: String.t() | nil
  def model_override(agent_name), do: field(agent_name, "model")

  @doc "Per-agent tier override (atom) from settings, or nil when unset/invalid."
  @spec tier_override(String.t() | nil) :: :elite | :specialist | :utility | nil
  def tier_override(agent_name) do
    case field(agent_name, "tier") do
      t when t in ["elite", "specialist", "utility"] -> String.to_existing_atom(t)
      _ -> nil
    end
  end

  @doc "The full overrides map (agent_name => %{...}), or an empty map."
  @spec all() :: %{optional(String.t()) => map()}
  def all do
    case Settings.get(@settings_key) do
      %{} = m -> m
      _ -> %{}
    end
  end

  defp field(nil, _key), do: nil

  defp field(agent_name, key) when is_binary(agent_name) do
    case Map.get(all(), agent_name) do
      %{} = a ->
        case Map.get(a, key) do
          v when is_binary(v) and v != "" -> v
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
