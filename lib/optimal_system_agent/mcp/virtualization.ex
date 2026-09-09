defmodule OptimalSystemAgent.MCP.Virtualization do
  @moduledoc """
  Decides whether MCP tools are *virtualized* (kept out of the base tool list
  and discovered on demand via `tool_search` + invoked via `use_tool`) or
  *injected directly* (every MCP tool schema in the model's default toolbox).

  This is OSA's port of grok-build's tool-virtualization gate (steal-list 11g):
  injecting a large MCP toolset into every prompt bloats context and dilutes the
  model's tool selection. Virtualization exposes two always-available meta-tools
  instead — `tool_search` (rank tool descriptions by a query) and `use_tool`
  (dispatch a discovered qualified `mcp__server__tool` by name) — and keeps the
  raw MCP tools deferred.

  ## Configurable, backward-compatible

  The decision is count-aware so small toolsets behave exactly as if
  virtualization did not exist (their tools are injected directly):

    * `config :optimal_system_agent, :mcp_virtualization` — `:auto` (default),
      `:on`, or `:off`.
        * `:auto` — virtualize only when the aggregate MCP tool count exceeds
          `threshold/0` (default #{10}). Below/at the threshold, tools inject
          directly. This is the "unchanged for small toolsets" path.
        * `:on`  — always virtualize when any MCP tool exists.
        * `:off` — never virtualize; always inject directly.
    * `config :optimal_system_agent, :mcp_virtualization_threshold` — integer N
      for the `:auto` cutoff (default #{10}).

  ## Where it applies

  `MCP.Client.Manager.republish/1` is the single writer of the aggregate
  `mcp_tools` map. It calls `apply_decision/1` on the aggregate, which stamps a
  uniform `:should_defer?` onto every entry based on the *total* count across
  all servers. `Tools.Registry.list_active/0` then reads that flag — no other
  module needs to know about virtualization.

  `use_tool` consults `active?/0` for its own loading semantics: it is deferred
  (hidden from the base prompt) precisely when virtualization is inactive, so
  the small-toolset prompt is unchanged.
  """

  @default_threshold 10
  @pt_key {OptimalSystemAgent.Tools.Registry, :mcp_tools}

  @type mode :: :auto | :on | :off

  @doc "The configured virtualization mode. Defaults to `:auto`."
  @spec mode() :: mode()
  def mode do
    case Application.get_env(:optimal_system_agent, :mcp_virtualization, :auto) do
      m when m in [:auto, :on, :off] -> m
      "auto" -> :auto
      "on" -> :on
      "off" -> :off
      true -> :on
      false -> :off
      _ -> :auto
    end
  end

  @doc "The `:auto`-mode cutoff: virtualize when count exceeds this. Defaults to #{@default_threshold}."
  @spec threshold() :: non_neg_integer()
  def threshold do
    case Application.get_env(
           :optimal_system_agent,
           :mcp_virtualization_threshold,
           @default_threshold
         ) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_threshold
    end
  end

  @doc """
  Whether an MCP toolset of `count` tools should be virtualized (deferred).

    * `:off`  → never
    * `:on`   → whenever `count > 0`
    * `:auto` → whenever `count > threshold()`
  """
  @spec virtualize?(non_neg_integer()) :: boolean()
  def virtualize?(count) when is_integer(count) and count >= 0 do
    case mode() do
      :off -> false
      :on -> count > 0
      :auto -> count > threshold()
    end
  end

  def virtualize?(_), do: false

  @doc "Whether virtualization is currently active for the live aggregate MCP toolset."
  @spec active?() :: boolean()
  def active?, do: virtualize?(current_count())

  @doc "Count of MCP tools currently published in `:persistent_term`."
  @spec current_count() :: non_neg_integer()
  def current_count do
    :persistent_term.get(@pt_key, %{}) |> map_size()
  end

  @doc """
  Stamp a uniform `:should_defer?` onto every entry of an aggregate `mcp_tools`
  map based on the total count. When virtualization is active every MCP tool is
  deferred (out of the base prompt); when inactive every MCP tool is injected
  directly. Pure — takes and returns a map.
  """
  @spec apply_decision(%{optional(String.t()) => map()}) :: %{optional(String.t()) => map()}
  def apply_decision(aggregate) when is_map(aggregate) do
    defer? = virtualize?(map_size(aggregate))
    Map.new(aggregate, fn {key, info} -> {key, Map.put(info, :should_defer?, defer?)} end)
  end

  @doc """
  Snapshot of what MCP tools currently cost the prompt, for surfacing to an
  operator (status bar, `/mcp` panel) who otherwise has no way to tell whether
  their connected servers are cheap or expensive.

  Reports the live aggregate tool/server count, whether virtualization is
  currently active for that count, and an ESTIMATED token cost of whatever is
  actually being shipped right now for MCP:

    * virtualized  → the rendered `<mcp-servers>` catalog text (capped names,
      see `Soul.ToolsSection.mcp_catalog_text/0`) — normally tiny (tens to a
      few hundred tokens) regardless of how many tools exist.
    * not virtualized → the JSON-encoded native schemas of every `mcp__`
      tool in `Registry.list_active/0` — the exact array a native-tool
      provider receives, so this can legitimately be large.

  The token count is a heuristic (`Utils.Tokens.estimate/1`), not the
  provider's real tokenizer — good enough for a status-bar order-of-magnitude,
  not for billing. Never raises: any failure reads as an all-zero snapshot
  rather than crashing whatever is trying to render it.
  """
  @spec cost_estimate() :: %{
          tool_count: non_neg_integer(),
          server_count: non_neg_integer(),
          virtualized: boolean(),
          estimated_tokens: non_neg_integer()
        }
  def cost_estimate do
    tool_count = current_count()
    virtualized? = virtualize?(tool_count)

    %{
      tool_count: tool_count,
      server_count: server_count(),
      virtualized: virtualized?,
      estimated_tokens: estimated_tokens(virtualized?)
    }
  rescue
    _ -> empty_cost_estimate()
  catch
    :exit, _ -> empty_cost_estimate()
  end

  defp empty_cost_estimate,
    do: %{tool_count: 0, server_count: 0, virtualized: false, estimated_tokens: 0}

  defp server_count do
    OptimalSystemAgent.Tools.Registry.mcp_servers() |> length()
  end

  # Whichever half is actually live right now: the capped catalog text when
  # virtualized, the native tool-array bytes when not. `apply_decision/1`
  # stamps `should_defer?` uniformly across the WHOLE aggregate (never a mix),
  # so exactly one of the two branches below has anything to measure and there
  # is no risk of double-counting.
  defp estimated_tokens(true) do
    case OptimalSystemAgent.Soul.ToolsSection.mcp_catalog_text() do
      text when is_binary(text) -> OptimalSystemAgent.Utils.Tokens.estimate(text)
      _ -> 0
    end
  end

  defp estimated_tokens(false) do
    OptimalSystemAgent.Tools.Registry.list_active()
    |> Enum.filter(fn tool -> OptimalSystemAgent.MCP.Client.ToolBridge.mcp_tool?(tool.name) end)
    |> Enum.map_join("", fn tool -> Jason.encode!(tool) end)
    |> OptimalSystemAgent.Utils.Tokens.estimate()
  end
end
