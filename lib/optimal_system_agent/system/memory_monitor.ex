defmodule OptimalSystemAgent.System.MemoryMonitor do
  @moduledoc """
  Watches the DAEMON'S OWN memory footprint and raises a rate-limited,
  visible TUI warning when it crosses a critical threshold.

  Before this, the only memory watchdog in the codebase was
  `MCP.Transport.Stdio`'s — and that one watches MCP *child* processes, not
  the OSA daemon itself. A daemon that grew unbounded (a huge session
  transcript, a leaking background task, an accumulating ETS table) gave no
  signal to the user at all until it OOM'd or the host started swapping.

  ## What is measured

  Two numbers, every check:

    * **BEAM total** (`:erlang.memory(:total)`) — everything the VM itself
      tracks: process heaps, ETS, binaries, loaded code.
    * **OS RSS** of this OS process (`ps -o rss= -p <self>`) — the number the
      kernel/host actually cares about, which can run ahead of the BEAM
      total (NIFs, ports, native libraries). This is the daemon's own RSS —
      the Rust TUI is a separate OS process with its own footprint.

  The critical threshold is checked against RSS when it is available (the
  more honest number for "is the host under pressure"), falling back to the
  BEAM total on platforms where `ps` is unavailable (Windows) or the read
  fails.

  ## Warn-only, on purpose

  Unlike `MCP.Transport.Stdio`'s hard limit — which *kills* the offending
  child, safe because an MCP server reconnects — this module never stops
  anything on its own. Auto-killing the daemon's own background work behind
  the user's back would destroy in-flight state with no reconnect path. The
  warning names concrete steps (finish/stop background tasks, compact,
  restart) and leaves the choice to the user. This is also why OSA's
  background shell commands are never auto-stopped for idle time or mild
  memory pressure (see `Shell.BackgroundTask.kill/2`) — Claude Code parity:
  a background command stops only on an explicit request, a session
  teardown, or (here) the user's own choice after being warned.

  ## Rate limiting

  A warning fires the instant the critical line is crossed, then re-arms
  only once memory drops back under it (so one excursion produces one
  warning, not one per check tick) — AND repeats at a bounded minimum
  interval (`renotify_ms/0`, default 10 minutes) while memory STAYS over the
  line, so a daemon pegged above the threshold for hours is not warned once
  and then silently forgotten.
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Events.Bus

  defstruct warned?: false, last_warned_at: nil

  # ── Config ──────────────────────────────────────────────────────────

  @doc "Sampling interval in ms. `nil` (or non-positive) disables the watchdog entirely."
  @spec check_ms() :: pos_integer() | nil
  def check_ms,
    do: Application.get_env(:optimal_system_agent, :daemon_memory_check_ms, 30_000)

  @doc "Critical RSS/BEAM-total threshold in MB. `nil` (or non-positive) disables warnings."
  @spec critical_mb() :: pos_integer() | nil
  def critical_mb,
    do: Application.get_env(:optimal_system_agent, :daemon_memory_critical_mb, 4_096)

  @doc """
  Minimum gap between repeat warnings while memory STAYS over the critical
  line. Without this a daemon pegged above the threshold for hours would warn
  exactly once and then go silent for the rest of the session.
  """
  @spec renotify_ms() :: pos_integer()
  def renotify_ms,
    do: Application.get_env(:optimal_system_agent, :daemon_memory_renotify_ms, 600_000)

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Current sample: `%{beam_mb: integer, rss_mb: integer | nil}`. Never raises."
  @spec sample() :: %{beam_mb: non_neg_integer(), rss_mb: non_neg_integer() | nil}
  def sample, do: %{beam_mb: beam_mb(), rss_mb: rss_mb()}

  @doc "BEAM-tracked total memory, in MB."
  @spec beam_mb() :: non_neg_integer()
  def beam_mb, do: div(:erlang.memory(:total), 1_048_576)

  @doc """
  Resident size of THIS OS process, in MB, or `nil` when it cannot be
  measured (Windows, or `ps` unavailable/failed).
  """
  @spec rss_mb() :: non_neg_integer() | nil
  def rss_mb do
    case :os.type() do
      {:win32, _} -> nil
      _ -> rss_mb_unix()
    end
  end

  defp rss_mb_unix do
    case System.cmd("ps", ["-o", "rss=", "-p", System.pid()], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.trim() |> Integer.parse() do
          {kb, _} -> div(kb, 1024)
          :error -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc "`true` when `mb` is at or past `limit` — mirrors `MCP.Transport.Stdio.exceeds?/2`."
  @spec exceeds?(integer() | nil, integer() | nil) :: boolean()
  def exceeds?(_mb, limit) when not is_integer(limit), do: false
  def exceeds?(mb, _limit) when not is_integer(mb), do: false
  def exceeds?(mb, limit), do: mb >= limit

  @doc """
  The critical-level notice: names the numbers AND concrete next steps
  (Claude Code parity — a warning that doesn't say what to do is noise).
  """
  @spec warning_message(integer(), integer()) :: String.t()
  def warning_message(mb, limit) do
    "OSA is using #{mb} MB, over the #{limit} MB threshold. To bring it down: " <>
      "finish or stop running background tasks (/bg), compact the conversation " <>
      "(/compact), or restart OSA."
  end

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:check, state) do
    schedule_check()
    {:noreply, tick(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_check do
    case check_ms() do
      ms when is_integer(ms) and ms > 0 -> Process.send_after(self(), :check, ms)
      _ -> :ok
    end
  end

  @doc false
  # The full check, folded into one GenServer-state transition so it can run
  # on a real timer tick. `decide/3` below is the pure core this delegates to
  # — tested directly, without a timer, a Port, or a real memory sample.
  @spec tick(t :: %__MODULE__{}) :: %__MODULE__{}
  def tick(state) do
    %{beam_mb: beam_mb, rss_mb: rss_mb} = sample()
    mb = rss_mb || beam_mb

    case decide(state, mb, critical_mb(), monotonic_ms()) do
      {:ok, new_state} ->
        new_state

      {:warn, new_state} ->
        Logger.warning(
          "[memory] daemon using #{mb} MB (RSS) / #{beam_mb} MB (BEAM total) — " <>
            "over the #{critical_mb()} MB critical threshold."
        )

        emit_warning(mb, beam_mb, critical_mb())
        new_state
    end
  end

  @doc """
  Pure decision core: given the current state, the measured `mb`, the
  configured `limit`, and "now" (monotonic ms), decide whether to warn.

  Returns `{:ok, state}` (nothing to do) or `{:warn, state}` (log + emit).
  Isolated from I/O so the rate-limit edge cases (first crossing, staying
  over, dropping back under and re-crossing, the renotify floor) are testable
  without a timer or a real process sample.
  """
  @spec decide(%__MODULE__{}, integer(), integer() | nil, integer()) ::
          {:ok | :warn, %__MODULE__{}}
  def decide(state, mb, limit, now_ms) do
    cond do
      not exceeds?(mb, limit) ->
        {:ok, %{state | warned?: false}}

      should_warn?(state, now_ms) ->
        {:warn, %{state | warned?: true, last_warned_at: now_ms}}

      true ->
        {:ok, state}
    end
  end

  defp should_warn?(%{warned?: false}, _now), do: true

  defp should_warn?(%{warned?: true, last_warned_at: at}, now) when is_integer(at),
    do: now - at >= renotify_ms()

  defp should_warn?(_state, _now), do: true

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp emit_warning(mb, beam_mb, limit) do
    Bus.emit(:system_event, %{
      event: :daemon_memory_warning,
      rss_mb: mb,
      beam_mb: beam_mb,
      limit_mb: limit,
      message: warning_message(mb, limit)
    })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
