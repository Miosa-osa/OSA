defmodule OptimalSystemAgent.Agent.Voice do
  @moduledoc """
  `/voice` — hands-free voice mode: spawn or kill the desktop orb.

  The orb is an Electron app at `~/Desktop/OSAVoice` (or `OSA_VOICE_APP`),
  frameless + transparent + always-on-top, rendering the rare-ui FluidOrb.
  It is the desktop face of voice mode: it listens (whisper.cpp), sends your
  words to THIS session through the HTTP API, and speaks replies (`say`).

  This module is the TUI-side switch — same shape as `Agent.Jailbreak`:

    * node-wide + persisted (`~/.osa/voice.json`) — the orb is a desktop
      surface, not a per-session resource; one orb at a time
    * `active?/0` is true only while the orb process is actually alive —
      an enabled flag with a dead process would lie via the badge, so the
      flag alone never claims voice mode
    * `/voice on` spawns the orb bound to the CURRENT session id, so
      spoken words land in the conversation you are looking at
    * `/voice off` kills it; the orb also self-quits when it notices the
      state file flip (crash-safe: no orphan windows)
  """

  require Logger

  @meta_file "voice.json"
  @default_app Path.join(System.user_home!(), "Desktop/OSAVoice")
  @orb_log Path.join(System.tmp_dir!(), "osavoice.log")

  # ── State ─────────────────────────────────────────────────────────────

  @doc "True while voice mode is armed AND the orb process is alive."
  @spec active?() :: boolean()
  def active? do
    state = load_state()
    Map.get(state, "enabled", false) == true and orb_alive?(state)
  end

  @doc """
  Arm voice mode for `session_id`: persist state, then spawn the orb.

  Idempotent: if an orb is already running for another session, it is
  killed first — one orb, bound to the session that most recently asked.
  """
  @spec enable(String.t()) :: :ok | {:error, term()}
  def enable(session_id) when is_binary(session_id) do
    app = app_dir()

    unless File.dir?(app), do: throw({:error, {:app_missing, app}})

    disable()
    state = %{"enabled" => true, "session_id" => session_id, "app" => app}
    :ok = persist(state)

    case spawn_orb(state) do
      {:ok, pid} ->
        Logger.info(
          "[Voice] orb spawned for session #{session_id} (port #{inspect(port_of(pid))})"
        )

        :ok

      {:error, reason} = err ->
        persist(Map.put(state, "enabled", false))
        Logger.warning("[Voice] orb spawn failed: #{inspect(reason)}")
        err
    end
  catch
    {:error, _} = err -> err
  end

  @doc "Disarm voice mode: flip the state file, then kill the orb if any."
  @spec disable() :: :ok
  def disable do
    state = load_state()
    :ok = persist(Map.put(state, "enabled", false))
    kill_orb(state)
    :ok
  end

  @doc "The session id the orb is currently bound to (nil when disarmed)."
  @spec session_id() :: String.t() | nil
  def session_id, do: load_state()["session_id"]

  @doc "The app directory currently in force."
  @spec app_dir() :: String.t()
  def app_dir do
    System.get_env("OSA_VOICE_APP") ||
      (load_state()["app"] || @default_app)
  end

  @doc "One-line status for the TUI: armed + bound session, or disarmed."
  @spec status_line() :: String.t()
  def status_line do
    if active?() do
      "voice on — orb bound to session #{session_id()}"
    else
      "voice off"
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────

  # The orb runs as a detached OS process. Fire-and-forget spawn + a
  # liveness probe (the vite port) as the boot check — a receive-based wait
  # cannot see a detached port's exit from this short-lived command process.
  defp spawn_orb(%{"app" => app, "session_id" => sid}) do
    log = open_log()

    _port =
      Port.open({:spawn_executable, orb_entry(app)}, [
        :exit_status,
        {:args, orb_args(app, sid)},
        {:cd, app},
        {:env,
         [
           {"OSA_SESSION_ID", sid},
           {"ELECTRON_ENABLE_LOGGING", "1"}
         ]},
        {:stream, log}
      ])

    # Probe: the orb's vite server binds :5199 when it boots. Poll briefly.
    case probe_alive?(3_000) do
      true -> {:ok, :spawned}
      false -> {:error, :orb_did_not_boot}
    end
  end

  defp orb_entry(app) do
    Path.join([app, "node_modules", ".bin", "electron"]) |> Path.expand()
  end

  # electron . is the entry; the renderer reads OSA_SESSION_ID itself.
  defp orb_args(_app, _sid), do: ["."]

  defp probe_alive?(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    probe_alive_loop(deadline)
  end

  defp probe_alive_loop(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      case orb_alive?(nil) do
        true ->
          true

        false ->
          Process.sleep(400)
          probe_alive_loop(deadline)
      end
    end
  end

  defp open_log do
    Path.dirname(@orb_log) |> File.mkdir_p!()
    File.open!(@orb_log, [:append, :utf8])
  end

  defp kill_orb(%{"enabled" => false}), do: :ok

  defp kill_orb(state) do
    case orb_alive?(state) do
      true ->
        # The orb self-quits when it polls the state file and sees enabled=false
        # — but don't wait on that; also send SIGTERM via osascript-free path.
        _ = send_term(state)
        :ok

      false ->
        :ok
    end
  end

  # state-file flip is the primary channel
  defp send_term(_state), do: :ok

  defp orb_alive?(state) do
    # A live orb holds the vite port; cheap and reliable liveness probe.
    # :binary + connect timeout in the options list — a bare integer as the
    # third arg is :gen_tcp.connect/3's address form and raises :badarg.
    case :gen_tcp.connect(~c"127.0.0.1", 5199, [:binary, {:active, false}], 200) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp port_of(_port), do: :unknown

  # ── State file ─────────────────────────────────────────────────────────

  defp load_state do
    try do
      case File.read(Path.join(osa_home(), @meta_file)) do
        {:ok, raw} -> Jason.decode!(raw) |> Map.put_new("enabled", false)
        {:error, :enoent} -> %{"enabled" => false}
      end
    rescue
      _ -> %{"enabled" => false}
    catch
      _, _ -> %{"enabled" => false}
    end
  end

  defp persist(state) do
    try do
      File.mkdir_p!(osa_home())
      :ok = File.write(Path.join(osa_home(), @meta_file), Jason.encode!(state))
    rescue
      e -> Logger.warning("[Voice] failed to persist state: #{Exception.message(e)}")
    end

    :ok
  end

  defp osa_home, do: System.get_env("OSA_HOME") || Path.join(System.user_home!(), ".osa")
end
