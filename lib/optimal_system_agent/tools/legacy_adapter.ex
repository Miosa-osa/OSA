defmodule OptimalSystemAgent.Tools.LegacyAdapter do
  @moduledoc """
  Wraps flat-layout tools so the registry sees a uniform surface.

  **Flat-layout tools** are single-file modules implementing
  `name/0, description/0, parameters/0, execute/1`, optionally
  `safety/0, available?/0, deferred?/0, concurrent?/0`.

  **Structured-layout tools** live in their own directory and implement
  the full `OptimalSystemAgent.Tools.Behaviour` contract — including
  `execute/2`, `validate_input/2`, `check_permissions/2`, `prompt/1`,
  `should_defer?/0`, `concurrency_safe?/2`, `read_only?/2`,
  `destructive?/2`, etc.

  This adapter is the load-bearing piece during the migration: it lets
  flat and structured tools coexist for as long as needed, with no
  feature flag and no big-bang rewrite.

  ## Routing rules

    * `structured?(mod)` — true iff the module exports `execute/2`
    * `execute/3`        — routes to structured (validate → check_permissions → execute) or flat (`execute/1`)
    * `concurrency_safe?/3` — uses the structured callback or falls back to flat `concurrent?/0`
    * `read_only?/3`     — structured callback, or `safety/0 == :read_only`
    * `destructive?/3`   — structured callback, or `safety/0 ∈ [:write_destructive, :terminal]`

  ## Error shape unification

  Flat tools return `{:error, String.t()}`. The structured `validate_input/2`
  returns `{:error, String.t(), code :: integer()}`. The adapter normalizes
  the structured error code away for the agent loop's consumers.

  ## Warn-once instrumentation

  When a flat tool is invoked through the adapter we emit a one-shot
  `Logger.warning` per `(session_id, tool_name)` so unmigrated tools are
  visible during ongoing migration without spamming logs.
  """

  require Logger

  alias OptimalSystemAgent.Permissions.AskFlow
  alias OptimalSystemAgent.Tools.UseContext

  @warn_once_table :osa_legacy_adapter_warned

  # ── Public API ────────────────────────────────────────────────────────

  @doc "True if `mod` exports the structured-layout `execute/2` callback."
  @spec structured?(module()) :: boolean()
  def structured?(mod) when is_atom(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :execute, 2)
  end

  def structured?(_), do: false

  @doc """
  Synthesize a uniform descriptor for a tool module. Used by
  `Registry.list_tools_direct/0` and `PromptAssembler.assemble/3` so
  callers see a consistent shape regardless of layout.
  """
  @spec normalize(module()) :: map()
  def normalize(mod) do
    %{
      module: mod,
      name: mod.name(),
      description: safe_call(mod, :description, 0, ""),
      parameters: safe_call(mod, :parameters, 0, %{}),
      aliases: safe_call(mod, :aliases, 0, []),
      search_hint: safe_call(mod, :search_hint, 0, ""),
      should_defer?: deferred?(mod),
      always_load?: safe_call(mod, :always_load?, 0, false),
      strict?: safe_call(mod, :strict?, 0, false),
      structured?: structured?(mod)
    }
  end

  @doc """
  Execute a tool, regardless of layout. Single entry point used by
  `Agent.Loop.ToolExecutor` and `Agent.Loop.ToolOrchestrator`.

  Returns `{:ok, result}` or `{:ok, result, metadata}` or
  `{:error, reason :: String.t()}`.
  """
  @spec execute(module(), map(), UseContext.t()) ::
          {:ok, any()} | {:ok, any(), map()} | {:error, String.t()}
  def execute(mod, input, %UseContext{} = ctx) when is_atom(mod) and is_map(input) do
    cond do
      structured?(mod) -> execute_structured(mod, input, ctx)
      function_exported?(mod, :execute, 1) -> execute_flat(mod, input, ctx)
      true -> {:error, "Tool #{inspect(mod)} has no execute/1 or execute/2"}
    end
  end

  @doc "Per-input concurrency check. Structured callback wins; falls back to flat `concurrent?/0`."
  @spec concurrency_safe?(module(), map(), UseContext.t()) :: boolean()
  def concurrency_safe?(mod, input, %UseContext{} = ctx) do
    cond do
      function_exported?(mod, :concurrency_safe?, 2) -> mod.concurrency_safe?(input, ctx)
      function_exported?(mod, :concurrent?, 0) -> mod.concurrent?()
      # Fail closed — matches buildTool default at Tool.ts:759
      true -> false
    end
  end

  @doc "Per-input read-only check. Structured callback wins; falls back to flat `safety/0`."
  @spec read_only?(module(), map(), UseContext.t()) :: boolean()
  def read_only?(mod, input, %UseContext{} = ctx) do
    cond do
      function_exported?(mod, :read_only?, 2) ->
        mod.read_only?(input, ctx)

      function_exported?(mod, :safety, 0) ->
        mod.safety() == :read_only

      true ->
        false
    end
  end

  @doc "Per-input destructive check. Structured callback wins; falls back to flat `safety/0`."
  @spec destructive?(module(), map(), UseContext.t()) :: boolean()
  def destructive?(mod, input, %UseContext{} = ctx) do
    cond do
      function_exported?(mod, :destructive?, 2) ->
        mod.destructive?(input, ctx)

      function_exported?(mod, :safety, 0) ->
        mod.safety() in [:write_destructive, :terminal]

      true ->
        false
    end
  end

  @doc "Module-level deferred check. Structured `should_defer?/0` wins; falls back to flat `deferred?/0`."
  @spec deferred?(module()) :: boolean()
  def deferred?(mod) do
    cond do
      function_exported?(mod, :should_defer?, 0) -> mod.should_defer?()
      function_exported?(mod, :deferred?, 0) -> mod.deferred?()
      true -> false
    end
  end

  @doc "Always-load check. Structured-only; flat tools always return false."
  @spec always_load?(module()) :: boolean()
  def always_load?(mod), do: safe_call(mod, :always_load?, 0, false)

  @doc "Max result size in chars before persisting to disk."
  @spec max_result_size_chars(module()) :: pos_integer() | :infinity
  def max_result_size_chars(mod), do: safe_call(mod, :max_result_size_chars, 0, 30_000)

  @doc "Render hook for the Rust TUI. Structured-only; flat tools return nil."
  @spec render(module(), atom(), any(), keyword()) :: map() | nil
  def render(mod, stage, payload, opts) do
    if function_exported?(mod, :render, 3) do
      mod.render(stage, payload, opts)
    else
      nil
    end
  end

  # ── Private: structured execution path ────────────────────────────────

  defp execute_structured(mod, input, ctx) do
    case validate_then_check(mod, input, ctx) do
      {:allow, allowed_input} ->
        mod.execute(allowed_input, ctx)

      {:error, msg, _code} ->
        {:error, msg}

      {:error, msg} ->
        {:error, msg}

      {:deny, reason} ->
        {:error, "Permission denied: #{reason}"}

      # The MIDDLE safety tier (`curl | sh`, `git push --force`, a write under
      # /etc). Park on the same PermissionBroker round-trip the agent loop
      # uses; a decline comes back as a NON-FATAL, model-readable refusal
      # (`ToolError.user_decision?/1` recognises the wording) so the turn
      # continues instead of dying on an internal error string. The VALIDATED
      # input is what runs on approval — the same value the `{:allow, _}`
      # branch would have executed.
      {:ask, prompt, valid_input} ->
        case AskFlow.request(mod_name(mod), valid_input, ctx, ask_reason(prompt)) do
          :allow -> mod.execute(valid_input, ctx)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ask_reason(prompt) when is_binary(prompt), do: prompt
  defp ask_reason(_), do: nil

  defp mod_name(mod), do: safe_call(mod, :name, 0, inspect(mod))

  defp validate_then_check(mod, input, ctx) do
    validate_fn =
      if function_exported?(mod, :validate_input, 2),
        do: &mod.validate_input/2,
        else: fn i, _c -> {:ok, i} end

    check_fn =
      if function_exported?(mod, :check_permissions, 2),
        do: &mod.check_permissions/2,
        else: fn i, _c -> {:allow, i} end

    case validate_fn.(input, ctx) do
      {:ok, valid} ->
        # Carry the validated input out with an `:ask` so the approval path
        # executes exactly what was checked, not the raw arguments.
        case check_fn.(valid, ctx) do
          {:ask, prompt} -> {:ask, prompt, valid}
          other -> other
        end

      {:error, msg, code} ->
        {:error, msg, code}

      other ->
        other
    end
  end

  # ── Private: flat execution path ──────────────────────────────────────

  defp execute_flat(mod, input, ctx) do
    warn_once(mod, ctx)
    mod.execute(input)
  end

  defp warn_once(mod, %UseContext{session_id: session_id}) do
    ensure_warn_table()
    name = safe_call(mod, :name, 0, inspect(mod))
    key = {session_id || "_no_session_", name}

    case :ets.insert_new(@warn_once_table, {key, true}) do
      true ->
        Logger.warning(
          "[LegacyAdapter] tool #{inspect(name)} uses flat execute/1 — migrate to structured execute/2 + UseContext"
        )

      false ->
        :ok
    end
  end

  defp ensure_warn_table do
    case :ets.whereis(@warn_once_table) do
      :undefined ->
        try do
          :ets.new(@warn_once_table, [:named_table, :public, :set, write_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  defp safe_call(mod, fun, arity, default) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity) do
      apply(mod, fun, [])
    else
      default
    end
  end
end
