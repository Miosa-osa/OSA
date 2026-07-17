defmodule OptimalSystemAgent.Agent.Loop.PermissionBroker do
  @moduledoc """
  Interactive permission round-trip park/resume store.

  Mirrors `Loop.Survey`: the tool-executing process (a serial ReAct step, or a
  `Task.async_stream` worker) blocks — polling ETS — after emitting a
  `permission_required` event, until the TUI's permission dialog POSTs a decision
  to `/api/v1/permissions/respond`, or the request times out / the session is
  cancelled.

  Three ETS tables (lazily created, public, survive the stateless HTTP request
  that fulfils the wait):

    * `:osa_permission_responses`      — `{request_id, decision_map}` written by
      the respond endpoint, read + deleted here.
    * `:osa_permission_session_allows` — `{{session_id, tool}, true}` for
      "allow for this session" decisions, so repeat calls short-circuit.
    * `:osa_cancel_flags`              — shared with the loop; a cancelled
      session aborts the wait so an interrupted turn never hangs.

  The decision vocabulary matches the TUI dialog (Allow / Session / Always /
  Deny / Clarify) and normalises to atoms:
  `:allow_once | :allow_session | :allow_always | :deny | :deny_always |
  :clarify`.
  """
  require Logger

  @responses :osa_permission_responses
  @session_allows :osa_permission_session_allows
  @cancel_table :osa_cancel_flags

  # Poll cadence + default ceiling. The ceiling is a safety net only: a
  # cancelled session (esc/interrupt) aborts far sooner via @cancel_table.
  @poll_interval_ms 150
  @default_timeout_ms 300_000

  @type decision :: %{
          decision:
            :allow_once | :allow_session | :allow_always | :deny | :deny_always | :clarify,
          note: String.t() | nil
        }

  @doc "Mint a unique, opaque permission request id."
  @spec new_request_id() :: String.t()
  def new_request_id, do: "perm_" <> Integer.to_string(System.unique_integer([:positive]))

  @doc """
  Record a client decision for `request_id`.

  Called by the HTTP respond endpoint. `raw` may be a decision string or a map
  with `"decision"`/`"note"` keys; it is normalised on read.
  """
  @spec respond(String.t(), term()) :: :ok
  def respond(request_id, raw) when is_binary(request_id) do
    ensure_table(@responses)
    :ets.insert(@responses, {request_id, normalize(raw)})
    :ok
  end

  def respond(_, _), do: :ok

  @doc """
  Block the caller until a decision for `request_id` arrives, the session is
  cancelled, or `:timeout` (default 5 min) elapses.

  Returns `{:ok, decision}` | `{:error, :timeout}` | `{:error, :cancelled}`.
  """
  @spec await(String.t() | nil, String.t(), keyword()) ::
          {:ok, decision()} | {:error, :timeout | :cancelled}
  def await(session_id, request_id, opts \\ []) when is_binary(request_id) do
    ensure_table(@responses)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    poll(session_id, request_id, timeout)
  end

  @doc "Remember an \"allow for this session\" grant for `tool`."
  @spec allow_for_session(String.t() | nil, String.t()) :: :ok
  def allow_for_session(session_id, tool) when is_binary(session_id) and is_binary(tool) do
    ensure_table(@session_allows)
    :ets.insert(@session_allows, {{session_id, tool}, true})
    :ok
  end

  def allow_for_session(_, _), do: :ok

  @doc "Whether `tool` was granted an \"allow for session\" earlier this session."
  @spec session_allowed?(String.t() | nil, String.t()) :: boolean()
  def session_allowed?(session_id, tool) when is_binary(session_id) and is_binary(tool) do
    ensure_table(@session_allows)

    case :ets.lookup(@session_allows, {session_id, tool}) do
      [{_, true}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  def session_allowed?(_, _), do: false

  @doc "Drop all session-scoped grants for a session (e.g. on session end)."
  @spec clear_session(String.t()) :: :ok
  def clear_session(session_id) when is_binary(session_id) do
    ensure_table(@session_allows)
    :ets.match_delete(@session_allows, {{session_id, :_}, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear_session(_), do: :ok

  # ── Private ──────────────────────────────────────────────────────────

  defp poll(_session_id, _request_id, timeout) when timeout <= 0, do: {:error, :timeout}

  defp poll(session_id, request_id, timeout) do
    if cancelled?(session_id) do
      {:error, :cancelled}
    else
      case :ets.lookup(@responses, request_id) do
        [{^request_id, decision}] ->
          :ets.delete(@responses, request_id)
          {:ok, decision}

        [] ->
          Process.sleep(@poll_interval_ms)
          poll(session_id, request_id, timeout - @poll_interval_ms)
      end
    end
  end

  defp cancelled?(session_id) when is_binary(session_id) do
    case :ets.lookup(@cancel_table, session_id) do
      [{_, true}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  defp cancelled?(_), do: false

  defp normalize(%{decision: _} = m),
    do: %{decision: decision_atom(m.decision), note: note_of(m)}

  defp normalize(%{"decision" => d} = m), do: %{decision: decision_atom(d), note: note_of(m)}
  defp normalize(d) when is_binary(d), do: %{decision: decision_atom(d), note: nil}
  defp normalize(d) when is_atom(d), do: %{decision: decision_atom(d), note: nil}
  defp normalize(_), do: %{decision: :deny, note: nil}

  defp note_of(m) when is_map(m) do
    note = Map.get(m, :note) || Map.get(m, "note") || Map.get(m, "clarify") || Map.get(m, "arg")
    if is_binary(note), do: note, else: nil
  end

  defp decision_atom(d) when is_atom(d), do: canonical(Atom.to_string(d))
  defp decision_atom(d) when is_binary(d), do: canonical(String.downcase(String.trim(d)))
  defp decision_atom(_), do: :deny

  defp canonical(s) do
    cond do
      s in ~w(allow allow_once once yes approve y) -> :allow_once
      s in ~w(session allow_session allow_for_session) -> :allow_session
      s in ~w(always allow_always) -> :allow_always
      s in ~w(deny reject no n decline) -> :deny
      s in ~w(deny_always reject_always never) -> :deny_always
      s in ~w(clarify steer edit reconsider) -> :clarify
      true -> :deny
    end
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end
end
