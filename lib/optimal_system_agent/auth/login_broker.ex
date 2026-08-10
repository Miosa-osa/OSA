defmodule OptimalSystemAgent.Auth.LoginBroker do
  @moduledoc """
  Run an account sign-in **out of band**, so a surface that cannot block can
  still complete one.

  ## The problem this exists to solve

  `Auth.Subscription.login/2` is a blocking call. For a device-code provider
  it prints a code, then polls for up to fifteen minutes. That is exactly
  right for `osa setup`, which owns the terminal for the duration — and it is
  unusable from anywhere else:

    * An HTTP request cannot hold a connection open for fifteen minutes, and a
      request that *starts* a grant and then returns has abandoned the poll.
      The user is shown a code with nothing waiting for it, which looks
      identical to a broken sign-in.
    * The TUI has to keep drawing. It needs the code and the URL as **data**
      it can render in a panel, a way to ask "are we there yet", and a way to
      cancel — not a function that takes the process hostage.

  So the flow runs in a supervised task and this module is the handle to it:
  start, poll for state, cancel. Every surface that is not a terminal goes
  through here, and the terminal surfaces stay on the direct call they
  already use.

  ## What is stored, and what is not

  A session holds the **user code and verification URL only** — the two things
  that are meant to be shown to a human and are useless to anyone who cannot
  also approve the grant in the provider's own UI. It never holds an access
  token, a refresh token or a device code. The credential goes straight to
  `SubscriptionStore` inside the flow; the broker learns only that it
  succeeded.

  ## One in-flight sign-in per provider

  Starting a second sign-in for a provider that already has one running
  returns the **existing** session rather than racing it. Two concurrent
  device grants for one provider produce two codes, one of which is
  guaranteed to be the wrong one to type, and the user has no way to tell
  which. Re-requesting is therefore treated as "show me the one I already
  have", which is what a user pressing Enter twice actually means.
  """

  use GenServer

  require Logger

  alias OptimalSystemAgent.Auth.LoginSession
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Onboarding

  # How long a finished session stays readable before it is swept. Long enough
  # for a poller on a slow interval to observe the terminal state — a session
  # that vanished the instant it succeeded would present to the TUI as "the
  # sign-in disappeared", which is the same screen as a failure.
  @retain_ms 120_000

  @typedoc "Everything a rendering surface needs. Contains no credential."
  @type session :: %{
          id: String.t(),
          provider: String.t(),
          state: :starting | :pending | :connected | :failed | :cancelled,
          user_code: String.t() | nil,
          verification_uri: String.t() | nil,
          verification_uri_complete: String.t() | nil,
          interval: pos_integer() | nil,
          expires_at: integer() | nil,
          message: String.t() | nil,
          error: String.t() | nil
        }

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @doc """
  Begin (or re-attach to) a sign-in for `provider`.

  Returns the session immediately. For a provider whose sign-in needs no user
  interaction the session will usually already be `:connected` by the time the
  caller polls; for a device-code provider it will be `:pending` with a code
  to render. **Callers do not need to know which** — that is the point of
  routing both through here, and it is what lets the TUI have one screen
  instead of a per-provider special case.
  """
  @spec start_login(String.t()) :: {:ok, session()} | {:error, term()}
  def start_login(provider) do
    GenServer.call(__MODULE__, {:start, to_string(provider)}, 15_000)
  end

  @doc "Current state of a session. `nil` once it has been swept."
  @spec status(String.t()) :: session() | nil
  def status(id), do: GenServer.call(__MODULE__, {:status, id})

  @doc """
  Ask a session to stop.

  Cooperative, via `LoginSession.request_cancel/1` — the poll loop notices
  between requests. Killing the task instead could abandon a grant
  mid-exchange, and the wait is never longer than one poll interval.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found}
  def cancel(id), do: GenServer.call(__MODULE__, {:cancel, id})

  @doc false
  @spec sessions() :: [session()]
  def sessions, do: GenServer.call(__MODULE__, :sessions)

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(:ok), do: {:ok, %{sessions: %{}, tasks: %{}}}

  @impl true
  def handle_call({:start, provider}, _from, state) do
    cond do
      not Subscription.supported?(provider) ->
        {:reply, {:error, :unsupported_provider}, state}

      not Subscription.available?(provider) ->
        {:reply, {:error, :not_configured}, state}

      existing = find_live(state, provider) ->
        # Re-attach rather than race. See the moduledoc.
        {:reply, {:ok, public(existing)}, state}

      true ->
        id = generate_id()
        broker = self()

        LoginSession.reset(provider)

        session = %{
          id: id,
          provider: provider,
          state: :starting,
          user_code: nil,
          verification_uri: nil,
          verification_uri_complete: nil,
          interval: nil,
          expires_at: nil,
          message: nil,
          error: nil,
          finished_at: nil
        }

        task =
          Task.Supervisor.async_nolink(
            OptimalSystemAgent.TaskSupervisor,
            fn -> run(broker, id, provider) end
          )

        state = %{
          state
          | sessions: Map.put(state.sessions, id, session),
            tasks: Map.put(state.tasks, task.ref, id)
        }

        {:reply, {:ok, public(session)}, state}
    end
  end

  def handle_call({:status, id}, _from, state) do
    {:reply, state.sessions |> Map.get(id) |> public(), state}
  end

  def handle_call({:cancel, id}, _from, state) do
    case Map.get(state.sessions, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{provider: provider} ->
        LoginSession.request_cancel(provider)
        {:reply, :ok, state}
    end
  end

  def handle_call(:sessions, _from, state) do
    {:reply, state.sessions |> Map.values() |> Enum.map(&public/1), state}
  end

  @impl true
  def handle_cast({:verification, id, info}, state) do
    {:noreply,
     update(state, id, fn session ->
       %{
         session
         | state: :pending,
           user_code: info[:user_code],
           verification_uri: info[:verification_uri],
           verification_uri_complete: info[:verification_uri_complete],
           interval: info[:interval],
           expires_at: info[:expires_in] && System.system_time(:second) + info[:expires_in]
       }
     end)}
  end

  def handle_cast({:finished, id, result}, state) do
    state = update(state, id, &apply_result(&1, result))
    Process.send_after(self(), {:sweep, id}, @retain_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:sweep, id}, state) do
    {:noreply, %{state | sessions: Map.delete(state.sessions, id)}}
  end

  # The task finished normally — its result was already reported by the cast
  # it sent before returning, so there is nothing to do but forget the ref.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | tasks: Map.delete(state.tasks, ref)}}
  end

  # The task CRASHED. Without this the session would sit at `:pending`
  # for ever and the TUI would spin on a sign-in that is already dead — the
  # single worst failure mode for a screen whose only job is to say what is
  # happening.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, tasks} ->
        {:noreply, %{state | tasks: tasks}}

      {id, tasks} ->
        Logger.warning("[Auth] sign-in task for session #{id} crashed: #{inspect(reason)}")

        state =
          update(%{state | tasks: tasks}, id, fn session ->
            %{
              session
              | state: :failed,
                error: "crashed",
                message:
                  "The sign-in stopped unexpectedly. Nothing was saved — try again, " <>
                    "and if it keeps happening please report it.",
                finished_at: System.monotonic_time(:millisecond)
            }
          end)

        Process.send_after(self(), {:sweep, id}, @retain_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── The flow itself ───────────────────────────────────────────────────────

  defp run(broker, id, provider) do
    result =
      Subscription.login(provider,
        # No terminal here. Line output is dropped rather than printed into a
        # gateway's JSON-RPC pipe; the structured `on_verification` callback
        # below is what this surface actually consumes.
        io: fn _ -> :ok end,
        # The browser is opened by the CLIENT, not by the server process. A
        # gateway serving a remote TUI opening a browser would open it on the
        # wrong machine — the user's screen is not necessarily this host's.
        open_browser: false,
        on_verification: fn info -> GenServer.cast(broker, {:verification, id, info}) end,
        on_tick: fn -> if LoginSession.cancelled?(provider), do: :cancel, else: :continue end
      )

    GenServer.cast(broker, {:finished, id, result})
    :ok
  end

  defp apply_result(session, {:ok, _entry}) do
    %{
      session
      | state: :connected,
        message: "Connected to #{display_name(session.provider)}.",
        finished_at: System.monotonic_time(:millisecond)
    }
  end

  defp apply_result(session, {:error, :cancelled}) do
    %{
      session
      | state: :cancelled,
        error: "cancelled",
        message: "Sign-in cancelled. Nothing was saved.",
        finished_at: System.monotonic_time(:millisecond)
    }
  end

  defp apply_result(session, {:error, reason}) do
    %{
      session
      | state: :failed,
        error: error_code(reason),
        message: Subscription.message(reason, display_name(session.provider)),
        finished_at: System.monotonic_time(:millisecond)
    }
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp find_live(state, provider) do
    Enum.find_value(state.sessions, fn {_id, s} ->
      if s.provider == provider and s.state in [:starting, :pending], do: s
    end)
  end

  defp update(state, id, fun) do
    case Map.get(state.sessions, id) do
      nil -> state
      session -> %{state | sessions: Map.put(state.sessions, id, fun.(session))}
    end
  end

  # The wire shape. `finished_at` is internal bookkeeping and is dropped, so
  # the serialized session is exactly the fields a surface may render.
  defp public(nil), do: nil
  defp public(session), do: Map.delete(session, :finished_at)

  defp error_code(reason) when is_atom(reason), do: to_string(reason)
  defp error_code(reason) when is_tuple(reason), do: to_string(elem(reason, 0))
  defp error_code(_), do: "sign_in_failed"

  defp display_name(provider) do
    case Enum.find(Onboarding.providers_list(), &(&1.id == provider)) do
      %{name: name} -> name
      _ -> provider
    end
  rescue
    _ -> provider
  end

  # 128 bits of CSPRNG. The id is a capability: anyone holding it can read the
  # session's state and cancel it, so it must not be guessable even though it
  # carries no credential.
  defp generate_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
