defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.PtyTest do
  @moduledoc """
  Tests for the OSA PTY executor.

  Spawns real PTYs via erlexec — tagged `:unix` to skip on Windows.

  Strategy:
    - `use ExUnit.Case, async: false` — tests run sequentially so the
      globally-named FrameRouter and PtyExecutor can be started once per
      test and torn down cleanly.
    - Each `setup` block starts a FrameRouter (named) and PtyExecutor (named),
      registers the test process as the FrameRouter's host_client, then
      tears everything down in `on_exit`.
    - Outbound frames arrive as `{:send_frame, frame}` messages to the test
      process — no mock library needed.
  """

  use ExUnit.Case, async: false

  @moduletag :unix

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Pty, as: PtyExecutor
  alias OptimalSystemAgent.OpenComputers.FrameRouter

  # ── Setup ────────────────────────────────────────────────────────────────────

  setup do
    # Stop any leftover named singletons synchronously before starting new ones.
    # GenServer.stop/3 blocks until the process exits (or timeout), so the next
    # start_link can safely reuse the same registered name.
    for mod <- [PtyExecutor, FrameRouter] do
      case Process.whereis(mod) do
        nil ->
          :ok

        pid ->
          try do
            GenServer.stop(pid, :normal, 2_000)
          catch
            :exit, _ -> :ok
          end
      end
    end

    {:ok, router_pid} = FrameRouter.start_link()
    {:ok, pty_pid} = PtyExecutor.start_link()

    # Register the test process as the host_client so outbound frames arrive
    # as {:send_frame, frame} messages.
    :ok = FrameRouter.register_host_client(self())

    {:ok, pty_pid: pty_pid, router_pid: router_pid}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp gen_session_id, do: Ecto.UUID.generate()

  # Collect the next outbound send_frame message matching a given frame tag.
  defp await_frame(tag, timeout_ms \\ 1_000) do
    receive do
      {:send_frame, {^tag, payload}} -> {:ok, payload}
    after
      timeout_ms -> {:timeout, tag}
    end
  end

  defp cast_to_pty(pty_pid, frame) do
    GenServer.cast(pty_pid, {:inbound, frame})
  end

  defp open_session(pty_pid, sid, opts \\ []) do
    cast_to_pty(
      pty_pid,
      {:pty_open_request,
       %{
         session_id: sid,
         shell: Keyword.get(opts, :shell, "/bin/sh"),
         cols: Keyword.get(opts, :cols, 80),
         rows: Keyword.get(opts, :rows, 24),
         cwd: Keyword.get(opts, :cwd, System.tmp_dir!()),
         env: Keyword.get(opts, :env, [])
       }}
    )
  end

  defp close_session(pty_pid, sid) do
    cast_to_pty(pty_pid, {:pty_close, %{session_id: sid, exit_code: nil}})
  end

  # ── Shell allowlist ───────────────────────────────────────────────────────────

  describe "shell allowlist" do
    test "pty_open_request with an allowed shell (/bin/sh) succeeds", %{pty_pid: pty_pid} do
      sid = gen_session_id()
      open_session(pty_pid, sid)

      assert {:ok, %{session_id: ^sid}} = await_frame(:pty_opened, 2_000)

      close_session(pty_pid, sid)
      # Drain pty_close frame so mailbox is clean
      await_frame(:pty_close, 500)
    end

    test "pty_open_request with disallowed shell emits pty_error :shell_not_allowed", %{
      pty_pid: pty_pid
    } do
      sid = gen_session_id()
      open_session(pty_pid, sid, shell: "/usr/bin/evil_shell_xyz")

      assert {:ok, %{session_id: ^sid, reason: :shell_not_allowed}} =
               await_frame(:pty_error, 1_000)
    end
  end

  # ── Happy path — interactive shell ───────────────────────────────────────────

  describe "interactive PTY session" do
    test "echo hello produces output within 500 ms", %{pty_pid: pty_pid} do
      sid = gen_session_id()
      open_session(pty_pid, sid)

      assert {:ok, _} = await_frame(:pty_opened, 2_000)

      cast_to_pty(pty_pid, {:pty_input, %{session_id: sid, data: "echo hello\n"}})

      assert_received_output(sid, "hello", 1_000)

      close_session(pty_pid, sid)
      await_frame(:pty_close, 1_000)
    end

    test "pty_close from OSA on shell self-exit — emits pty_close with exit_code 0", %{
      pty_pid: pty_pid
    } do
      sid = gen_session_id()
      open_session(pty_pid, sid)

      assert {:ok, _} = await_frame(:pty_opened, 2_000)

      # Shell exits itself cleanly
      cast_to_pty(pty_pid, {:pty_input, %{session_id: sid, data: "exit 0\n"}})

      assert {:ok, payload} = await_frame(:pty_close, 5_000)
      assert payload.session_id == sid
      assert payload.exit_code == 0
    end
  end

  # ── Geometry / resize ────────────────────────────────────────────────────────

  describe "resize" do
    test "pty_resize is accepted without crashing for a running session", %{pty_pid: pty_pid} do
      sid = gen_session_id()
      open_session(pty_pid, sid)

      assert {:ok, _} = await_frame(:pty_opened, 2_000)

      cast_to_pty(pty_pid, {:pty_resize, %{session_id: sid, cols: 132, rows: 43}})
      Process.sleep(50)

      assert Process.alive?(pty_pid)

      close_session(pty_pid, sid)
      await_frame(:pty_close, 1_000)
    end

    test "pty_resize for unknown session is silently ignored", %{pty_pid: pty_pid} do
      cast_to_pty(
        pty_pid,
        {:pty_resize,
         %{
           session_id: "nonexistent-session",
           cols: 80,
           rows: 24
         }}
      )

      assert [] == pty_frames_before_sentinel(pty_pid)
      assert Process.alive?(pty_pid)
    end
  end

  # ── Unknown session handling ──────────────────────────────────────────────────

  describe "unknown session" do
    test "pty_input for unknown session is silently dropped", %{pty_pid: pty_pid} do
      cast_to_pty(pty_pid, {:pty_input, %{session_id: "ghost-session", data: "ls\n"}})

      assert [] == pty_frames_before_sentinel(pty_pid)
      assert Process.alive?(pty_pid)
    end

    test "pty_close for unknown session is silently ignored", %{pty_pid: pty_pid} do
      cast_to_pty(pty_pid, {:pty_close, %{session_id: "ghost-session", exit_code: nil}})
      Process.sleep(50)
      assert Process.alive?(pty_pid)
    end
  end

  # ── Multiple concurrent sessions ─────────────────────────────────────────────

  describe "multiple concurrent sessions" do
    test "output from each session is dispatched with the correct session_id", %{pty_pid: pty_pid} do
      sid_a = gen_session_id()
      sid_b = gen_session_id()

      open_session(pty_pid, sid_a)
      open_session(pty_pid, sid_b)

      # Wait for both to open
      assert {:ok, _} = await_frame(:pty_opened, 2_000)
      assert {:ok, _} = await_frame(:pty_opened, 2_000)

      cast_to_pty(pty_pid, {:pty_input, %{session_id: sid_a, data: "echo session_a_tag\n"}})
      cast_to_pty(pty_pid, {:pty_input, %{session_id: sid_b, data: "echo session_b_tag\n"}})

      outputs = collect_output_frames(300)

      for {sid, _data} <- outputs do
        assert sid in [sid_a, sid_b],
               "unexpected session_id #{sid} in output frames"
      end

      close_session(pty_pid, sid_a)
      close_session(pty_pid, sid_b)
      Process.sleep(200)
    end
  end

  # ── Private test helpers ──────────────────────────────────────────────────────

  # Deterministic replacement for `refute_received {:send_frame, _}`.
  #
  # Two things were wrong with the old shape:
  #
  #   1. `refute_received` only says "nothing had arrived *yet*". It passed by
  #      being faster than the executor, not because the executor stayed quiet,
  #      so it could never have failed reliably either.
  #   2. This mailbox is not exclusively ours. `FrameRouter` is a globally
  #      named singleton and the test process is its registered host_client, so
  #      *any* executor's outbound frame lands here — including a
  #      `{:clipboard_synced, _}` from a `Task.start/1` in `Clipboard` that
  #      outlived the clipboard test that spawned it. Absence of *anything* was
  #      never the property being tested; absence of a *pty* frame was.
  #
  # So assert on ordering instead of on time. `GenServer.cast/2` into
  # PtyExecutor is FIFO and every outbound frame is relayed through the single
  # FrameRouter, so a frame produced by the frame under test would necessarily
  # be delivered before one produced by a later cast. We enqueue a sentinel
  # that provokes a known reply, drain until it arrives, and return every pty
  # frame seen ahead of it — which must be none. Foreign frames are ignored
  # rather than failing the test.
  defp pty_frames_before_sentinel(pty_pid, timeout_ms \\ 2_000) do
    sentinel_sid = gen_session_id()
    open_session(pty_pid, sentinel_sid, shell: "/usr/bin/sentinel_shell_not_allowed")
    collect_until_sentinel(sentinel_sid, timeout_ms, [])
  end

  defp collect_until_sentinel(sentinel_sid, timeout_ms, acc) do
    receive do
      {:send_frame, {:pty_error, %{session_id: ^sentinel_sid, reason: :shell_not_allowed}}} ->
        Enum.reverse(acc)

      {:send_frame, {tag, _payload} = frame} when is_atom(tag) ->
        if pty_frame?(tag) do
          collect_until_sentinel(sentinel_sid, timeout_ms, [frame | acc])
        else
          collect_until_sentinel(sentinel_sid, timeout_ms, acc)
        end

      {:send_frame, _other} ->
        collect_until_sentinel(sentinel_sid, timeout_ms, acc)
    after
      timeout_ms ->
        flunk(
          "sentinel pty_error frame never arrived within #{timeout_ms}ms — " <>
            "cannot conclude anything about what the executor did or did not emit"
        )
    end
  end

  defp pty_frame?(tag), do: tag |> Atom.to_string() |> String.starts_with?("pty_")

  defp assert_received_output(session_id, needle, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_received_output(session_id, needle, deadline, "")
  end

  defp do_assert_received_output(session_id, needle, deadline, acc) do
    now = System.monotonic_time(:millisecond)
    remaining = max(deadline - now, 0)

    receive do
      {:send_frame, {:pty_output, %{session_id: ^session_id, data: data}}} ->
        combined = acc <> data

        if String.contains?(combined, needle) do
          :ok
        else
          do_assert_received_output(session_id, needle, deadline, combined)
        end

      {:send_frame, _other} ->
        do_assert_received_output(session_id, needle, deadline, acc)
    after
      remaining ->
        flunk("Expected #{inspect(needle)} within timeout. Accumulated: #{inspect(acc)}")
    end
  end

  defp collect_output_frames(timeout_ms) do
    do_collect_output(timeout_ms, [])
  end

  defp do_collect_output(remaining, acc) when remaining <= 0, do: Enum.reverse(acc)

  defp do_collect_output(remaining, acc) do
    receive do
      {:send_frame, {:pty_output, %{session_id: sid, data: data}}} ->
        do_collect_output(remaining - 10, [{sid, data} | acc])

      {:send_frame, _} ->
        do_collect_output(remaining - 10, acc)
    after
      10 ->
        do_collect_output(remaining - 10, acc)
    end
  end
end
