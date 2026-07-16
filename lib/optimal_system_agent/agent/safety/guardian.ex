defmodule OptimalSystemAgent.Agent.Safety.Guardian do
  @moduledoc """
  MECHANISM: stateful enforcement of the auto-mode safety policy.

  The Guardian is the only safety layer that touches state or the outside world.
  It **never classifies** — it delegates that entirely to `Classifier` — and then
  applies enforcement:

    * `:safe` / `:caution` verdicts → `{:allow}`
    * `:dangerous` verdicts        → block, increment a session-scoped counter,
      emit `:auto_mode_blocked`, and — once the counter reaches the configured
      `pause_after_blocks` threshold — flip the session into a paused state and
      emit `:auto_mode_paused`, returning `{:pause, reason}`.

  Once a session is paused, every subsequent `review/2` returns `{:pause, _}`
  until it is explicitly resumed via `resume/1` / `reset/1`.

  State lives in the `:osa_auto_mode` ETS table (created in `Application.start`),
  mirroring the `:osa_files_read` pattern:

      {{session_id, :blocks}, integer_count}
      {{session_id, :paused}, true}
  """

  require Logger

  alias OptimalSystemAgent.Agent.Safety.{Classifier, ModelClassifier, Verdict}
  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Store.SessionTranscript

  @table :osa_auto_mode
  @default_pause_after 3

  @type review_result :: {:allow} | {:block, String.t()} | {:pause, String.t()}

  @doc """
  Review a tool call for a session running in `:auto` permission tier.

  Returns `{:allow}`, `{:block, reason}`, or `{:pause, reason}`. Purely reads the
  verdict from `Classifier` and applies the stateful pause-after-N mechanism.
  """
  @spec review(map(), map()) :: review_result()
  def review(tool_call, state) do
    session_id = Map.get(state, :session_id)

    cond do
      is_nil(session_id) ->
        # No session to scope state to — fail closed on dangerous, else allow.
        review_stateless(tool_call, state)

      paused?(session_id) ->
        {:pause, "auto-mode is paused pending human review — resume to continue"}

      true ->
        verdict = classify(tool_call, state)
        enforce(verdict, session_id)
    end
  end

  # ── enforcement ──────────────────────────────────────────────────────

  defp enforce(%Verdict{risk: risk} = _v, _session_id) when risk in [:safe, :caution],
    do: {:allow}

  defp enforce(%Verdict{risk: :dangerous} = verdict, session_id) do
    count = increment_blocks(session_id)
    threshold = pause_after_blocks()

    emit(:auto_mode_blocked, session_id, verdict, %{block_count: count, threshold: threshold})

    if count >= threshold do
      mark_paused(session_id)
      emit(:auto_mode_paused, session_id, verdict, %{block_count: count, threshold: threshold})
      record_denial(session_id, verdict, count, :pause)

      {:pause,
       "#{verdict.reason} — #{count} dangerous action(s) blocked, auto-mode paused for review"}
    else
      record_denial(session_id, verdict, count, :block)
      {:block, verdict.reason}
    end
  end

  # When there is no session id we cannot keep a counter; block dangerous calls
  # outright and allow everything else. Still never classifies inline.
  defp review_stateless(tool_call, state) do
    case classify(tool_call, state) do
      %Verdict{risk: :dangerous} = v -> {:block, v.reason}
      _ -> {:allow}
    end
  end

  # Produce the verdict for a tool call. When the optional model-based classifier
  # is enabled (`:auto_mode` → `:model_classifier` → `:enabled`), the verdict is
  # the higher risk of the rules and the model/heuristic assessment — so a
  # dangerous verdict from EITHER path blocks. When it is off (the default), this
  # is byte-for-byte the original pure rule-based path.
  defp classify(tool_call, state) do
    ctx = build_ctx(state)

    if ModelClassifier.enabled?() do
      ModelClassifier.classify(tool_call, ctx)
    else
      Classifier.classify(
        Map.get(tool_call, :name),
        Map.get(tool_call, :arguments, %{}),
        ctx
      )
    end
  end

  # ── pause / resume state ─────────────────────────────────────────────

  @doc "True when the session is currently paused by the Guardian."
  @spec paused?(String.t()) :: boolean()
  def paused?(session_id) when is_binary(session_id) do
    case safe_lookup({session_id, :paused}) do
      [{_key, true}] -> true
      _ -> false
    end
  end

  def paused?(_), do: false

  @doc "Number of dangerous tool calls blocked in this session so far."
  @spec block_count(String.t()) :: non_neg_integer()
  def block_count(session_id) when is_binary(session_id) do
    case safe_lookup({session_id, :blocks}) do
      [{_key, n}] when is_integer(n) -> n
      _ -> 0
    end
  end

  def block_count(_), do: 0

  @doc """
  Clear the Guardian pause for a session and reset its block counter so the
  agent loop can resume unattended execution.
  """
  @spec resume(String.t()) :: :ok
  def resume(session_id) when is_binary(session_id) do
    reset(session_id)
    Logger.info("[guardian] Auto-mode resumed for session #{session_id}")
    :ok
  end

  def resume(_), do: :ok

  @doc "Reset all Guardian state (block counter + pause flag) for a session."
  @spec reset(String.t()) :: :ok
  def reset(session_id) when is_binary(session_id) do
    safe_delete({session_id, :blocks})
    safe_delete({session_id, :paused})
    :ok
  end

  def reset(_), do: :ok

  # ── config ───────────────────────────────────────────────────────────

  @doc "Configured pause-after-N-blocks threshold."
  @spec pause_after_blocks() :: pos_integer()
  def pause_after_blocks do
    config() |> Keyword.get(:pause_after_blocks, @default_pause_after)
  end

  @doc "Configured trusted-host allowlist for the untrusted_network check."
  @spec untrusted_host_allowlist() :: [String.t()]
  def untrusted_host_allowlist do
    config() |> Keyword.get(:untrusted_host_allowlist, [])
  end

  defp config, do: Application.get_env(:optimal_system_agent, :auto_mode, [])

  # Build the classifier ctx from config + state. `ctx` allowlist may be
  # overridden per-session via state.untrusted_host_allowlist.
  defp build_ctx(state) do
    ctx = %{
      untrusted_host_allowlist:
        Map.get(state, :untrusted_host_allowlist) || untrusted_host_allowlist(),
      session_id: Map.get(state, :session_id)
    }

    # Optional deterministic model-assessment hook (tests / custom integrations).
    case Map.get(state, :assessor) do
      fun when is_function(fun, 2) -> Map.put(ctx, :assessor, fun)
      _ -> ctx
    end
  end

  # ── denial transcript recording ──────────────────────────────────────

  # Record the denial reason to the session transcript so a blocked/paused
  # action is auditable alongside the conversation. Best-effort and fully
  # isolated: a missing Repo (bare unit tests) never crashes enforcement, since
  # `SessionTranscript.save_turn/4` already rescues its own failures.
  defp record_denial(session_id, %Verdict{} = verdict, count, outcome)
       when is_binary(session_id) do
    content =
      "[auto-mode #{outcome}] #{verdict.reason} " <>
        "(tool=#{verdict.tool || "?"}, category=#{verdict.category}, " <>
        "source=#{denial_source(verdict)}, block ##{count})"

    SessionTranscript.save_turn(session_id, "system", content, tool_name: verdict.tool)
  rescue
    _ -> {:error, :skipped}
  catch
    _, _ -> {:error, :skipped}
  end

  defp record_denial(_session_id, _verdict, _count, _outcome), do: {:error, :no_session}

  defp denial_source(%Verdict{category: :model_flagged}), do: "model"
  defp denial_source(%Verdict{}), do: "rules"

  # ── ETS helpers (mirror :osa_files_read usage) ───────────────────────

  defp increment_blocks(session_id) do
    key = {session_id, :blocks}
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  rescue
    ArgumentError ->
      # Table missing (e.g. in a bare unit test) — degrade to 1 so a single
      # dangerous call still blocks, without crashing the loop.
      1
  end

  defp mark_paused(session_id) do
    safe_insert({{session_id, :paused}, true})
  end

  defp safe_lookup(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp safe_insert(row) do
    :ets.insert(@table, row)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── event emission (Bus + PubSub) ────────────────────────────────────

  defp emit(event_type, session_id, %Verdict{} = verdict, extra) do
    payload =
      Map.merge(
        %{
          session_id: session_id,
          tool: verdict.tool,
          category: verdict.category,
          matched_rule: verdict.matched_rule,
          reason: verdict.reason
        },
        extra
      )

    Bus.emit(event_type, payload, source: "guardian", session_id: session_id)

    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event, Map.put(payload, :type, event_type)}
    )
  rescue
    _ -> :ok
  end
end
