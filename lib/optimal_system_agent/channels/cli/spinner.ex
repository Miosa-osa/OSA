defmodule OptimalSystemAgent.Channels.CLI.Spinner do
  @moduledoc """
  CLI activity feed — shows live tool calls, reasoning iterations,
  and token usage as the agent works. Like Claude Code's tool display.

  Displays like:
    ⠋ Thinking… (2s)
    ├─ file_read — lib/agent/loop.ex (120ms)
    ├─ shell_exec — mix test (3.2s)
    ⠹ Reasoning… (8s · 2 tools · ↓ 4.2k)
  """

  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  @frame_interval 80
  @rotate_interval 4_000

  @status_messages [
    # ── OSA / Signal Theory ──
    "Classifying signals…",
    "Filtering noise…",
    "Maximizing S/N ratio…",
    "Traversing the signal space…",
    "Resolving the 5-tuple…",
    "Encoding optimal intent…",
    "Applying Shannon constraints…",
    "Walking the path of least resistance…",
    "Calibrating signal weight…",
    # ── Elixir / BEAM ──
    "Spawning processes on the BEAM…",
    "Pattern matching on your intent…",
    "Reducing over the possibilities…",
    "Supervising child processes…",
    "Hot-reloading a better answer…",
    "Let it crash… then recover gracefully…",
    "Piping through the pipeline…",
    # ── Dev humor ──
    "Reticulating splines…",
    "Converting coffee into code…",
    "Trying to exit Vim…",
    "Looking for a misplaced semicolon…",
    "Rewriting in Rust for no particular reason…",
    "Applying percussive maintenance…",
    "Resolving dependencies… and existential crises…",
    "That's not a bug, it's an undocumented feature…",
    "Compiling brilliance…",
    "Untangling neural nets…",
    "Polishing the algorithms…",
    "Brewing fresh bytes…",
    "Optimizing for ludicrous speed…",
    "Calibrating the flux capacitor…",
    "Constructing additional pylons…",
    "Herding digital cats…",
    "Mining for more Dilithium crystals…",
    "Blowing on the cartridge…",
    "Checking for syntax errors in the universe…",
    # ── Pop culture ──
    "Don't panic…",
    "Following the white rabbit…",
    "Engaging the improbability drive…",
    "Finishing the Kessel Run in less than 12 parsecs…",
    "So say we all…",
    "Engage.",
    "Warp speed engaged…",
    "Pondering the orb…",
    "Is this the real life? Is this just fantasy?…",
    # ── Self-aware ──
    "Thinking harder than strictly necessary…",
    "Almost there… probably…",
    "Letting the thoughts marinate…",
    "Warming up the AI hamsters…",
    "Our agents are working as fast as they can…",
    "Asking the magic conch shell…",
    "Consulting the digital spirits…",
    "Buffering… because even AIs need a moment…",
    # ── Dev jokes ──
    "Why do programmers prefer dark mode? Light attracts bugs…",
    "Why did the developer go broke? Used up all their cache…"
  ]

  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @reset IO.ANSI.reset()

  defstruct [
    :started_at,
    :parent,
    phase: :thinking,
    active_tool: nil,
    tool_count: 0,
    total_tokens: 0,
    iteration: 0,
    status_index: 0,
    last_rotate: 0
  ]

  @doc "Start the spinner. Returns the spinner pid."
  @spec start() :: pid()
  def start do
    parent = self()
    spawn(fn -> init_loop(parent) end)
  end

  @doc "Stop the spinner. Returns {elapsed_ms, tool_count, total_tokens}."
  @spec stop(pid()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def stop(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, {:stop, self()})

      receive do
        {:spinner_stats, elapsed_ms, tool_count, total_tokens} ->
          Process.demonitor(ref, [:flush])
          {elapsed_ms, tool_count, total_tokens}

        {:DOWN, ^ref, :process, ^pid, _} ->
          {0, 0, 0}
      after
        500 ->
          Process.demonitor(ref, [:flush])
          Process.exit(pid, :kill)
          {0, 0, 0}
      end
    else
      {0, 0, 0}
    end
  end

  @doc "Send a state update to the spinner."
  @spec update(pid(), term()) :: :ok
  def update(pid, msg) do
    if Process.alive?(pid), do: send(pid, msg)
    :ok
  end

  # --- Internal loop ---

  defp init_loop(parent) do
    now = System.monotonic_time(:millisecond)

    state = %__MODULE__{
      started_at: now,
      parent: parent,
      last_rotate: now
    }

    spinner_loop(@spinner_frames, state)
  end

  defp spinner_loop([], state), do: spinner_loop(@spinner_frames, state)

  defp spinner_loop([frame | rest], state) do
    now = System.monotonic_time(:millisecond)

    # Maybe rotate status message
    state =
      if state.phase == :thinking and now - state.last_rotate >= @rotate_interval do
        next = :rand.uniform(length(@status_messages)) - 1
        # Avoid immediate repeat
        next = if next == state.status_index and length(@status_messages) > 1,
          do: rem(next + 1, length(@status_messages)), else: next
        %{state | status_index: next, last_rotate: now}
      else
        state
      end

    render_frame(frame, state)

    receive do
      {:stop, caller} ->
        clear_line()
        elapsed_ms = System.monotonic_time(:millisecond) - state.started_at
        send(caller, {:spinner_stats, elapsed_ms, state.tool_count, state.total_tokens})

      {:tool_start, name, args} ->
        spinner_loop(rest, %{
          state
          | phase: :tool_running,
            active_tool: {name, args, System.monotonic_time(:millisecond)}
        })

      {:tool_end, name, ms} ->
        # Print completed tool as a permanent line, then continue spinning
        clear_line()
        hint = tool_hint(state.active_tool)
        duration = format_duration(ms)
        IO.puts("#{@dim}  ├─ #{name}#{hint} #{@cyan}(#{duration})#{@reset}")

        spinner_loop(rest, %{
          state
          | phase: :thinking,
            active_tool: nil,
            tool_count: state.tool_count + 1
        })

      {:llm_response, usage} ->
        tokens = Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
        new_iter = state.iteration + 1

        # Show iteration marker when agent loops (tool → re-prompt)
        if new_iter > 1 do
          clear_line()
          IO.puts("#{@dim}  │  iteration #{new_iter}#{@reset}")
        end

        spinner_loop(rest, %{
          state
          | total_tokens: state.total_tokens + tokens,
            iteration: new_iter
        })
    after
      @frame_interval ->
        if Process.alive?(state.parent) do
          spinner_loop(rest, state)
        end
    end
  end

  defp render_frame(frame, state) do
    now = System.monotonic_time(:millisecond)
    elapsed = format_elapsed(now - state.started_at)
    tokens_str = format_tokens(state.total_tokens)
    tools_str = if state.tool_count > 0, do: " · #{state.tool_count} tools", else: ""

    status =
      case state.phase do
        :tool_running ->
          {name, args, _start} = state.active_tool
          if args != "", do: "#{name} — #{truncate(args, 50)}", else: "#{name}…"

        :thinking ->
          Enum.at(@status_messages, state.status_index)
      end

    clear_line()
    IO.write("#{@dim}  #{frame} #{status} (#{elapsed}#{tools_str}#{tokens_str})#{@reset}")
  end

  # --- Formatting helpers ---

  defp tool_hint({_name, args, _start}) when is_binary(args) and args != "" do
    " — #{truncate(args, 45)}"
  end

  defp tool_hint(_), do: ""

  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1_000, 1)}s"

  defp format_elapsed(ms) when ms < 1_000, do: "<1s"
  defp format_elapsed(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"

  defp format_elapsed(ms) do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1_000)
    "#{mins}m#{secs}s"
  end

  defp format_tokens(0), do: ""
  defp format_tokens(n) when n < 1_000, do: " · ↓ #{n}"
  defp format_tokens(n), do: " · ↓ #{Float.round(n / 1_000, 1)}k"

  defp truncate(str, max),
    do: OptimalSystemAgent.Utils.Text.truncate(str, max)

  defp clear_line do
    width =
      case :io.columns() do
        {:ok, cols} -> cols
        _ -> 80
      end

    IO.write("\r#{String.duplicate(" ", width)}\r")
  end
end
