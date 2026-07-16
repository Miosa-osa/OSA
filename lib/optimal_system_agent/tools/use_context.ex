defmodule OptimalSystemAgent.Tools.UseContext do
  @moduledoc """
  Per-call execution context. Mirrors `ToolUseContext` at
  upstream
  Built once per turn by `OptimalSystemAgent.Agent.Loop.ReactLoop` and
  passed to every tool's `validate_input/2`, `check_permissions/2`,
  `execute/2`, `render/3`, and `concurrency_safe?/2`.

  Fields are kept narrow on purpose — adding a field is cheap, removing
  one is a breaking change for every migrated tool. Use `extras` for
  anything experimental.
  """

  defstruct [
    # ── Session identity ─────────────────────────────────────────────
    :session_id,
    :agent_id,
    :agent_type,
    :tool_use_id,

    # ── Permission rules ─────────
    :permission_mode,
    :always_allow_rules,
    :always_deny_rules,
    :always_ask_rules,
    :additional_working_dirs,

    # ── Permission tier (kept alongside rules during the migration) ──
    :permission_tier,

    # ── Per-agent gating ─────────────────────────────────────────────
    :allowed_tools,
    :blocked_tools,

    # ── Caches & state ───────────────────────────────────────────────
    :file_state_cache,
    :messages,
    :read_only_request?,
    :is_non_interactive?,

    # ── Budgets ──────────────────────────────────────────────────────
    :max_budget_usd,
    :budget_used_usd,
    :max_turns,

    # ── Cancellation ─────────────────────────────────────────────────
    :abort_ref,

    # ── Telemetry & events ───────────────────────────────────────────
    :emit,

    # ── Cross-tool references (for prompt assembly) ──────────────────
    :tools,
    :agents,

    # ── Delegation nesting depth (fork-bomb / runaway-cost guard) ─────
    # 0 for a top-level session; incremented for each subagent generation.
    # The delegate handler reads this to propagate depth into spawned children.
    delegation_depth: 0,

    # ── Extension point ──────────────────────────────────────────────
    extras: %{}
  ]

  @type permission_mode :: :default | :plan | :auto | :bypass
  @type permission_tier :: :read_only | :workspace | :full | :subagent

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          agent_id: String.t() | nil,
          agent_type: atom() | String.t() | nil,
          tool_use_id: String.t() | nil,
          permission_mode: permission_mode() | nil,
          always_allow_rules: map(),
          always_deny_rules: map(),
          always_ask_rules: map(),
          additional_working_dirs: map(),
          permission_tier: permission_tier() | nil,
          delegation_depth: non_neg_integer(),
          allowed_tools: [String.t()] | nil,
          blocked_tools: [String.t()],
          file_state_cache: map(),
          messages: list(),
          read_only_request?: boolean(),
          is_non_interactive?: boolean(),
          max_budget_usd: float() | nil,
          budget_used_usd: float(),
          max_turns: pos_integer() | nil,
          abort_ref: pid() | reference() | nil,
          emit: (atom(), map() -> :ok) | nil,
          tools: [module() | map()],
          agents: [map()],
          extras: map()
        }

  @doc """
  Build a `UseContext` from an agent loop state map. Missing fields take
  safe defaults — never raise on a partial state.
  """
  @spec new(map(), keyword()) :: t()
  def new(state \\ %{}, opts \\ []) do
    %__MODULE__{
      session_id: Map.get(state, :session_id) || Map.get(state, "session_id"),
      agent_id: Map.get(state, :agent_id),
      agent_type: Map.get(state, :agent_type),
      tool_use_id: Keyword.get(opts, :tool_use_id),
      permission_mode: Map.get(state, :permission_mode, :default),
      permission_tier: Map.get(state, :permission_tier, :full),
      always_allow_rules: Map.get(state, :always_allow_rules, %{}),
      always_deny_rules: Map.get(state, :always_deny_rules, %{}),
      always_ask_rules: Map.get(state, :always_ask_rules, %{}),
      additional_working_dirs: Map.get(state, :additional_working_dirs, %{}),
      allowed_tools: Map.get(state, :allowed_tools),
      blocked_tools: Map.get(state, :blocked_tools, []),
      file_state_cache: Map.get(state, :file_state_cache, %{}),
      messages: Map.get(state, :messages, []),
      read_only_request?: Map.get(state, :read_only_request?, false),
      is_non_interactive?: Map.get(state, :is_non_interactive?, false),
      max_budget_usd: Map.get(state, :max_budget_usd),
      budget_used_usd: Map.get(state, :budget_used_usd, 0.0),
      max_turns: Map.get(state, :max_turns),
      abort_ref: Map.get(state, :abort_ref),
      delegation_depth: Map.get(state, :delegation_depth, 0),
      emit: Keyword.get(opts, :emit),
      tools: Keyword.get(opts, :tools, []),
      agents: Keyword.get(opts, :agents, []),
      extras: Keyword.get(opts, :extras, %{})
    }
  end

  @doc """
  Empty context for tests and non-interactive callers. Permission tier
  is `:read_only` by default — tests must explicitly opt into more.
  """
  @spec empty() :: t()
  def empty do
    %__MODULE__{
      session_id: "test",
      permission_mode: :default,
      permission_tier: :read_only,
      always_allow_rules: %{},
      always_deny_rules: %{},
      always_ask_rules: %{},
      additional_working_dirs: %{},
      blocked_tools: [],
      file_state_cache: %{},
      messages: [],
      read_only_request?: false,
      is_non_interactive?: true,
      budget_used_usd: 0.0,
      tools: [],
      agents: [],
      extras: %{}
    }
  end
end
