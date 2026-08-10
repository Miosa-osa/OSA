defmodule OptimalSystemAgent.Auth.LoginSession do
  @moduledoc """
  Cancellation and progress for a device-code sign-in that is otherwise a
  blocking, silent, fifteen-minute wait.

  ## What was wrong

  Both device-code flows already accepted an `on_tick` callback, already
  returned `{:error, :cancelled}` when it answered `:cancel`, and already had a
  written user-facing message for that case. Nothing ever passed one. Both
  production call sites — `CLI.Setup` and the setup wizard — supplied only
  `io:`, so the `:cancelled` branch was unreachable code guarding a message no
  user could ever see. Meanwhile the poll is a `Process.sleep/1` recursion in
  the caller's own process, and `io` is invoked once, before it starts.

  The visible result: after printing the code, OSA goes completely silent for
  up to fifteen minutes, Esc does nothing, and Ctrl-C takes down the BEAM
  through the break handler rather than cancelling the sign-in.

  This module supplies the missing half. It is deliberately tiny and holds no
  credential — a boolean and a counter per provider, nothing else. (The audit
  note about a `:public, :named_table` ETS holding a PKCE verifier is about a
  different table; there is nothing here worth reading.)

  ## Three sources of cancellation, one flag

    * **Ctrl-C** — `SIGINT` is trapped for the duration of the flow and
      restored afterwards, so the interrupt cancels the sign-in instead of
      killing the VM. Trapping is scoped, never global: `with_cancellation/2`
      restores the previous disposition in an `after`, including on a crash.
    * **The TUI** — calls `request_cancel/1` (over the gateway) when the user
      presses Esc on the sign-in screen.
    * **A timeout** — the flows keep their own deadline; this module does not
      duplicate it.

  ## Progress

  `on_tick/2` also writes a heartbeat, because the second-worst thing after an
  uncancellable wait is an indistinguishable one: a user cannot tell a poll
  that is working from a process that has hung. It writes a dot per tick and a
  minute marker, which is enough to be obviously alive without turning a
  fifteen-minute wait into fifteen minutes of scrollback.
  """

  require Logger

  @table :osa_login_sessions

  # ── Flag storage ────────────────────────────────────────────────────────

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table])
        rescue
          # Lost a race with another process creating it. Either way it now
          # exists, which is all the caller needs.
          ArgumentError -> @table
        end

      _ ->
        @table
    end
  end

  @doc "Clear any stale cancel flag and tick count for a provider. Call before a flow starts."
  @spec reset(String.t() | atom()) :: :ok
  def reset(provider) do
    :ets.insert(table(), {key(provider), false, 0})
    :ok
  end

  @doc """
  Ask the in-flight sign-in for `provider` to stop.

  Cooperative by design: it sets a flag the poll loop reads between requests
  rather than killing the polling process. A sign-in aborted mid-exchange
  could leave a grant half-completed on the provider's side, and the wait
  between two polls is never longer than the poll interval.
  """
  @spec request_cancel(String.t() | atom()) :: :ok
  def request_cancel(provider) do
    :ets.insert(table(), {key(provider), true, 0})
    :ok
  end

  @doc "True when a cancel has been requested for this provider's in-flight sign-in."
  @spec cancelled?(String.t() | atom()) :: boolean()
  def cancelled?(provider) do
    case :ets.lookup(table(), key(provider)) do
      [{_, true, _}] -> true
      _ -> false
    end
  end

  defp key(provider), do: {:login, to_string(provider)}

  defp bump(provider) do
    :ets.update_counter(table(), key(provider), {3, 1}, {key(provider), false, 0})
  rescue
    _ -> 0
  end

  # ── The callback the flows want ─────────────────────────────────────────

  @doc """
  Build the zero-arity `on_tick` callback the device flows expect.

  Returns `:cancel` once a cancel has been requested, `:continue` otherwise,
  and writes a heartbeat as a side effect. `write` takes a string and returns
  anything; it defaults to `IO.write/1` and is injectable so tests can assert
  on the progress output without a terminal.
  """
  @spec on_tick(String.t() | atom(), (String.t() -> any())) :: (-> :continue | :cancel)
  def on_tick(provider, write \\ &IO.write/1) do
    fn ->
      if cancelled?(provider) do
        safe_write(write, "\n")
        :cancel
      else
        heartbeat(bump(provider), write)
        :continue
      end
    end
  end

  # A dot per poll, a minute marker every twelfth (the flows poll at ~5s).
  # Cheap enough to be unconditional and quiet enough to leave on.
  defp heartbeat(n, write) when is_integer(n) do
    cond do
      n > 0 and rem(n, 12) == 0 -> safe_write(write, " #{div(n, 12)}m ")
      true -> safe_write(write, ".")
    end
  end

  defp heartbeat(_, _), do: :ok

  # Progress output must never be able to fail a sign-in. A closed stdout (the
  # gateway runs with stdout as a JSON-RPC pipe) is not a reason to abandon a
  # grant the user has already approved in their browser.
  defp safe_write(write, text) do
    write.(text)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ── SIGINT scoping ──────────────────────────────────────────────────────

  @doc """
  Run `fun` with Ctrl-C rebound to "cancel this sign-in".

  The previous `SIGINT` disposition is restored in an `after`, so an exception
  inside `fun` cannot leave the VM with a hijacked interrupt key — which would
  be a far worse bug than the one this fixes.

  On any platform or release where signal handling is unavailable, `fun` runs
  unchanged: losing Ctrl-C cancellation is a degraded experience, not a reason
  to refuse to sign in.
  """
  @spec with_cancellation(String.t() | atom(), (-> result)) :: result when result: term()
  def with_cancellation(provider, fun) when is_function(fun, 0) do
    reset(provider)

    case install_sigint_handler(provider) do
      {:ok, handler_id} ->
        try do
          fun.()
        after
          remove_sigint_handler(handler_id)
        end

      :unavailable ->
        fun.()
    end
  end

  defp install_sigint_handler(provider) do
    handler_id = {__MODULE__.SigintHandler, make_ref()}

    with :ok <- set_signal(:sigint, :handle),
         :ok <- :gen_event.add_handler(:erl_signal_server, handler_id, provider) do
      {:ok, handler_id}
    else
      _ ->
        _ = set_signal(:sigint, :default)
        :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  defp remove_sigint_handler(handler_id) do
    _ = :gen_event.delete_handler(:erl_signal_server, handler_id, :normal)
    _ = set_signal(:sigint, :default)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp set_signal(signal, disposition) do
    :os.set_signal(signal, disposition)
    :ok
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defmodule SigintHandler do
    @moduledoc """
    `:gen_event` handler installed on `:erl_signal_server` for the duration of
    a sign-in. Its whole job is to turn one `:sigint` notification into one
    cancel flag.

    It deliberately does **not** stop the VM on a second interrupt. A user who
    presses Ctrl-C twice during a sign-in wants out of the sign-in, not out of
    their session, and the flow returns within one poll interval anyway.
    """
    @behaviour :gen_event

    alias OptimalSystemAgent.Auth.LoginSession

    @impl true
    def init(provider), do: {:ok, provider}

    @impl true
    def handle_event(:sigint, provider) do
      LoginSession.request_cancel(provider)
      {:ok, provider}
    end

    def handle_event(_other, provider), do: {:ok, provider}

    @impl true
    def handle_call(_request, provider), do: {:ok, :ok, provider}

    @impl true
    def handle_info(_msg, provider), do: {:ok, provider}

    @impl true
    def terminate(_reason, _provider), do: :ok
  end
end
