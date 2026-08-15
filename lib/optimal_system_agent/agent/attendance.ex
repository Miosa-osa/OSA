defmodule OptimalSystemAgent.Agent.Attendance do
  @moduledoc """
  **Can a human respond on this session right now?** One answer, derived.

  ## The question that had no owner

  Three blocking paths park a tool-executing process waiting for a person:
  `Loop.PermissionBroker.await/3` (300 s), `Loop.Survey.ask/4` (120 s), and the
  `Permissions.AskFlow` prompt built on the first. Whether anyone is there to
  answer was decided by two unconnected mechanisms, neither of which knew about
  the other:

    * `state.channel` — `:cli | :headless | :internal | :http | :scheduler`
      (never `:tui`), which nothing consulted for this purpose; and
    * an application-env flag `:interactive_permissions`, read from a private
      one-line function **duplicated verbatim in three modules**
      (`Loop.ToolExecutor`, `Permissions.AskFlow`, `Channels.CLI.Session`),
      defaulting to `true`, and never set by anything that runs headless.

  So `mix osa.run` — which sets `channel: :headless` and touches no flag — took
  the interactive branch and could park for five minutes per prompt with nobody
  attached to the session, repeatedly, for the length of the run. Nothing in the
  system could state the difference between an attended and an unattended
  session, which is also why `/ask-user` had to ship off-by-default: the
  distinction it needed did not exist.

  This module is that distinction. It is derived, not duplicated: callers ask
  `attended?/1` and never read the flag themselves.

  ## Resolution order

  Highest priority first:

    1. **Sticky per-session override** — `put_override/2`, ETS. What an operator
       explicitly declared for THIS session (`/attend on|off`, an SDK caller
       that knows better than the channel does).
    2. **`OSA_ATTENDED` env var** — `1/true/yes/on` / `0/false/no/off`. The
       escape hatch for a headless invocation that DOES have a human watching,
       and for a CLI wrapper driving OSA from a script.
    3. **`:interactive_permissions == false`** — a hard veto. Explicitly
       disabling interactive permissions has always meant "do not prompt", and
       `config/test.exs` and existing deployments rely on it. `true` carries no
       information (it is the default) and is therefore NOT treated as a claim
       that someone is present.
    4. **The session's channel**, registered by `Loop.init/1`:
       `:cli`/`:tui`/`:http` are attended (a TUI or HTTP client is what answers
       `POST /api/v1/permissions/respond`); `:headless`/`:scheduler` are not;
       `:internal` — a subagent — inherits from its parent, walking the
       `RunStore` chain to the root, which is exactly the chain
       `ToolExecutor.permission_topics/1` publishes the prompt along.
    5. **A TTY probe** for a session with no registered channel: `:io.columns/0`
       succeeds only on a terminal. It can only vote YES — no tty is not
       evidence of absence (a TUI client attached over HTTP has no tty on the
       server side).
    6. **The legacy `:interactive_permissions` flag** (default `true`) for a
       session that is still unidentified after all of the above. This is
       deliberately the PRE-Attendance answer: a synthetic or unregistered
       session must not be *newly* silenced by a derivation with nothing to
       derive from, because "unattended" routes to a fail-closed auto-decision
       and quietly turning previously-prompted calls into auto-decisions is a
       change to a permission boundary, not a bug fix. Every session the loop
       actually starts registers a channel at step 4 and never reaches here.

  Nothing here can be made *more* attended by accident: every layer that says
  "yes" is either an explicit operator act, a real signal (a channel with a
  client, a terminal), or the behaviour that already existed.

  ## What "unattended" must NOT mean

  It must never mean self-approval. An unattended session that reaches a
  permission prompt fails closed — `ToolExecutor.non_interactive_decision/1`
  and `AskFlow.non_interactive_decision/2`, both of which honour the explicit
  `:non_interactive_permission_bypass` opt-out and nothing else. The change here
  is that it fails closed **immediately and audibly** instead of after a silent
  five-minute stall.

  ## Not persisted to disk

  Like `Agent.AskUserMode`, the sticky override lives in ETS only, so a daemon
  restart drops it and every surface re-derives the same answer from the
  channel. `Agent.PermissionMode` persists because a permission GRANT must
  survive a restart; "is someone watching" is a property of the current
  attachment and would be a lie the moment it outlived one.
  """

  require Logger

  alias OptimalSystemAgent.Agent.RunStore

  @table :osa_session_attendance
  @env_var "OSA_ATTENDED"
  @truthy ~w(1 true yes on attended)
  @falsy ~w(0 false no off unattended headless)

  # Channels with a client that can render a prompt and POST a decision.
  @attended_channels [:cli, :tui, :http]
  # Channels that provably have nobody attached.
  @unattended_channels [:headless, :scheduler]

  @max_parent_hops 16

  # ── Session registration ──────────────────────────────────────────────

  @doc """
  Record the channel a session runs on. Called once by `Loop.init/1`.

  Storing the CHANNEL rather than a boolean keeps the derivation in one place:
  the veto in step 3 and the parent walk in step 4 still apply on every read,
  which they could not if the answer were frozen at session start.
  """
  @spec put_channel(String.t() | nil, atom()) :: :ok
  def put_channel(session_id, channel) when is_binary(session_id) and is_atom(channel) do
    ensure_table()
    :ets.insert(@table, {{:channel, session_id}, channel})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put_channel(_, _), do: :ok

  @doc "The channel registered for `session_id`, or `nil`."
  @spec channel(String.t() | nil) :: atom() | nil
  def channel(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, {:channel, session_id}) do
      [{_, ch}] -> ch
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def channel(_), do: nil

  @doc "Explicitly declare attendance for `session_id`, overriding every derivation."
  @spec put_override(String.t() | nil, boolean()) :: :ok
  def put_override(session_id, attended?)
      when is_binary(session_id) and is_boolean(attended?) do
    ensure_table()
    :ets.insert(@table, {{:override, session_id}, attended?})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put_override(_, _), do: :ok

  @doc "Drop everything remembered for `session_id` (session end)."
  @spec clear(String.t() | nil) :: :ok
  def clear(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, {:channel, session_id})
    :ets.delete(@table, {:override, session_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear(_), do: :ok

  @doc "The sticky override for `session_id`, or `nil` when none was set."
  @spec override(String.t() | nil) :: boolean() | nil
  def override(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, {:override, session_id}) do
      [{_, v}] -> v
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def override(_), do: nil

  # ── The question ──────────────────────────────────────────────────────

  @doc """
  Can a human respond on this session right now?

  Accepts a session id, a loop state map (`%{session_id: _, channel: _}`), or
  `nil`. Never raises: any failure resolves to `false`, which is the direction
  that fails closed — a session that cannot answer the question must not be one
  that parks waiting for an answer.
  """
  @spec attended?(String.t() | map() | nil) :: boolean()
  def attended?(state) when is_map(state) do
    sid = Map.get(state, :session_id)
    # A state map carries its own channel; prefer it over the registry, which
    # may not have been written yet during `Loop.init/1` itself.
    case Map.get(state, :channel) do
      ch when is_atom(ch) and not is_nil(ch) -> resolve(sid, ch)
      _ -> attended?(sid)
    end
  end

  def attended?(session_id), do: resolve(session_id, channel(session_id))

  defp resolve(session_id, ch) do
    cond do
      is_boolean(o = override(session_id)) -> o
      is_boolean(e = env_attended()) -> e
      interactive_disabled?() -> false
      is_atom(ch) and not is_nil(ch) -> attended_channel?(ch, session_id, @max_parent_hops)
      # Steps 5-6 — see the moduledoc. An UNREGISTERED session keeps exactly the
      # pre-Attendance answer rather than being newly silenced by a derivation
      # that has nothing to derive from.
      true -> unidentified()
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  A short reason for the current verdict — for the log line that accompanies a
  non-interactive auto-decision, so an operator can see WHY nothing was asked.
  """
  @spec reason(String.t() | map() | nil) :: String.t()
  def reason(state) when is_map(state), do: reason_for(Map.get(state, :session_id))
  def reason(session_id), do: reason_for(session_id)

  defp reason_for(session_id) do
    cond do
      is_boolean(o = override(session_id)) -> "session override (attended=#{o})"
      is_boolean(e = env_attended()) -> "#{@env_var}=#{e}"
      interactive_disabled?() -> "interactive_permissions is disabled"
      ch = channel(session_id) -> "channel #{inspect(ch)}"
      tty?() -> "stdout is a terminal"
      true -> "unregistered session; interactive_permissions=#{legacy_flag()}"
    end
  rescue
    _ -> "unknown"
  end

  # ── Derivations ───────────────────────────────────────────────────────

  defp env_attended do
    case System.get_env(@env_var) do
      v when is_binary(v) ->
        v = v |> String.trim() |> String.downcase()

        cond do
          v in @truthy -> true
          v in @falsy -> false
          true -> nil
        end

      _ ->
        nil
    end
  end

  # A hard veto only in the `false` direction. `true` is the config default and
  # therefore says nothing about whether a person exists.
  defp interactive_disabled?, do: legacy_flag() == false

  # The pre-Attendance signal, now a LAYER inside the one answer rather than a
  # private one-liner copied into three modules.
  defp legacy_flag,
    do: Application.get_env(:optimal_system_agent, :interactive_permissions, true) != false

  defp attended_channel?(ch, _session_id, _hops) when ch in @attended_channels, do: true
  defp attended_channel?(ch, _session_id, _hops) when ch in @unattended_channels, do: false

  # `:internal` is a subagent. Its prompt IS deliverable — `permission_topics/1`
  # republishes it on every ancestor up to the root, and `respond/2` is keyed by
  # request id alone — so the honest answer is the ROOT's, not `false`.
  #
  # Walked iteratively with a hop budget AND a seen-set: a cycle in the RunStore
  # ledger must terminate, and it must terminate at `false` rather than at a
  # guess.
  defp attended_channel?(:internal, session_id, hops),
    do: walk_to_root(session_id, hops, MapSet.new([session_id]))

  defp attended_channel?(_, _session_id, _hops), do: unidentified()

  # A dead end in the ancestry (no parent on record, a cycle, or the hop budget)
  # leaves the subagent exactly as UNIDENTIFIED as a session with no channel at
  # all — so it gets the same step 5/6 answer, not a hard `false`. Deciding
  # "unattended" from an absence of evidence would newly convert prompts into
  # fail-closed auto-decisions, which is a permission-boundary change.
  defp walk_to_root(_session_id, hops, _seen) when hops <= 0, do: unidentified()

  defp walk_to_root(session_id, hops, seen) do
    case parent_of(session_id) do
      nil ->
        unidentified()

      parent ->
        cond do
          MapSet.member?(seen, parent) ->
            unidentified()

          # An explicit override or a known channel on the ancestor settles it.
          is_boolean(o = override(parent)) ->
            o

          ch = channel(parent) ->
            if ch == :internal,
              do: walk_to_root(parent, hops - 1, MapSet.put(seen, parent)),
              else: attended_channel?(ch, parent, hops - 1)

          true ->
            walk_to_root(parent, hops - 1, MapSet.put(seen, parent))
        end
    end
  end

  # Steps 5 and 6, shared by "no channel registered" and "ancestry unknown".
  defp unidentified, do: tty?() or legacy_flag()

  defp parent_of(session_id) when is_binary(session_id) do
    case RunStore.get(session_id) do
      %{parent_session_id: p} when is_binary(p) and p not in ["", "unknown"] -> p
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp parent_of(_), do: nil

  @doc """
  Is stdout a terminal? The last real signal before giving up.

  `:io.columns/0` answers `{:ok, _}` only for a tty device; a pipe or a
  detached daemon gets `{:error, :enotsup}`.
  """
  @spec tty?() :: boolean()
  def tty? do
    match?({:ok, _}, :io.columns())
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
