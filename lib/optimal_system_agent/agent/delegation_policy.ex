defmodule OptimalSystemAgent.Agent.DelegationPolicy do
  @moduledoc """
  Tri-mode delegation policy — a thread/turn-level control over when the agent
  may spawn subagents via the `delegate` tool (Codex-parity, primitive #34).

  Modes:

    * `:disabled`      — the agent may never delegate. `delegate` (and its
      spawning aliases) is stripped from the tool list entirely, and any direct
      call is denied at the handler.
    * `:explicit_only` — the agent may delegate ONLY when the user explicitly
      asked for it in the current turn (keyword intent on the latest user
      message). Otherwise the spawning tools are stripped / a call is denied.
    * `:proactive`     — the agent may delegate freely (current behaviour).

  The policy is orthogonal to — and layered on top of — the existing delegation
  *depth* guard in `Loop.ToolFilter`: depth caps runaway nesting; policy caps
  *whether* delegation is permitted at all for this session/turn.

  Resolution order for the effective policy:

    1. the loop/session state field `:delegation_policy` (per-session override), then
    2. the application env `config :optimal_system_agent, :delegation_policy, MODE`, then
    3. the built-in default `:proactive` (preserves prior behaviour).

  Both the string forms (`"explicit-only"`) and the atom forms
  (`:explicit_only`) are accepted so HTTP/config callers and internal callers
  share one normaliser.
  """

  @modes [:disabled, :explicit_only, :proactive]
  @default :proactive

  # Keyword intent for `:explicit_only` — matched (case-insensitively) against
  # the latest user message. Deliberately broad but delegation-specific so an
  # incidental mention ("delegate") counts while ordinary work does not.
  @intent_regex ~r/\b(delegate|sub-?agents?|spawn|fan[-\s]?out|in parallel|parallel agents?|dispatch (?:an? |the )?agent|worker agents?|farm out|delegate to)\b/i

  @doc "The three supported delegation modes."
  @spec modes() :: [atom()]
  def modes, do: @modes

  @doc "The built-in default mode (`:proactive`)."
  @spec default_mode() :: atom()
  def default_mode, do: @default

  @doc """
  The configured default policy — application env, falling back to `:proactive`.
  Always returns a normalised atom in `modes/0`.
  """
  @spec configured_default() :: atom()
  def configured_default do
    Application.get_env(:optimal_system_agent, :delegation_policy, @default) |> normalize()
  end

  @doc """
  Normalise a policy given as an atom or string into one of `modes/0`.
  Unknown / nil values fall back to the built-in default.
  """
  @spec normalize(term()) :: atom()
  def normalize(mode) when mode in @modes, do: mode

  def normalize(str) when is_binary(str) do
    case str |> String.trim() |> String.downcase() do
      "disabled" -> :disabled
      "off" -> :disabled
      "none" -> :disabled
      "explicit" -> :explicit_only
      "explicit-only" -> :explicit_only
      "explicit_only" -> :explicit_only
      "proactive" -> :proactive
      "auto" -> :proactive
      "on" -> :proactive
      _ -> @default
    end
  end

  def normalize(_), do: @default

  @doc """
  Resolve the effective policy from a state/context map (or struct). Reads the
  `:delegation_policy` field (atom or string key), else falls back to the
  configured default. Never raises on a partial map.
  """
  @spec resolve(map()) :: atom()
  def resolve(state) when is_map(state) do
    case Map.get(state, :delegation_policy) || Map.get(state, "delegation_policy") do
      nil -> configured_default()
      value -> normalize(value)
    end
  end

  def resolve(_), do: configured_default()

  @doc """
  Whether delegation is permitted right now, given a policy atom and the current
  message history. `:proactive` always allows, `:disabled` never, and
  `:explicit_only` allows only when the user asked for delegation this turn.
  """
  @spec allow?(atom(), list()) :: boolean()
  def allow?(:proactive, _messages), do: true
  def allow?(:disabled, _messages), do: false
  def allow?(:explicit_only, messages), do: user_requested?(messages)
  def allow?(other, messages), do: allow?(normalize(other), messages)

  @doc """
  Convenience: resolve the policy from `state` and decide whether delegation is
  currently allowed, reading `state.messages` for the intent check.
  """
  @spec allow?(map()) :: boolean()
  def allow?(state) when is_map(state) do
    allow?(resolve(state), Map.get(state, :messages) || Map.get(state, "messages") || [])
  end

  @doc """
  Whether the user explicitly requested delegation in the latest user message.
  Used to gate `:explicit_only`.
  """
  @spec user_requested?(list()) :: boolean()
  def user_requested?(messages) when is_list(messages) do
    case latest_user_text(messages) do
      text when is_binary(text) and text != "" -> Regex.match?(@intent_regex, text)
      _ -> false
    end
  end

  def user_requested?(_), do: false

  # ── Private ────────────────────────────────────────────────────────────

  defp latest_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      if is_map(msg) do
        role = to_string(Map.get(msg, :role) || Map.get(msg, "role") || "")
        if role == "user", do: extract_text(Map.get(msg, :content) || Map.get(msg, "content"))
      end
    end)
  end

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => t} when is_binary(t) -> t
      %{text: t} when is_binary(t) -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
    |> Enum.join(" ")
  end

  defp extract_text(_), do: ""
end
