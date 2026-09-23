defmodule OptimalSystemAgent.System.MemoryMonitorTest do
  @moduledoc """
  Nothing watched the DAEMON's own memory before this — only MCP child
  processes (`MCP.Transport.Stdio`). A daemon that grew unbounded gave no
  signal to the user until it OOM'd. These tests pin:

    * the pure threshold/decision logic (no timer, no real memory sample),
    * that a warning fires once per crossing and re-arms on drop-below,
    * that a SUSTAINED critical excursion still re-warns after the renotify
      floor instead of going silent forever,
    * that the daemon never auto-stops anything — warn-only.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.System.MemoryMonitor, as: MM

  describe "exceeds?/2" do
    test "at or past the limit trips it" do
      assert MM.exceeds?(4_096, 4_096)
      assert MM.exceeds?(9_000, 4_096)
    end

    test "under the limit does not" do
      refute MM.exceeds?(4_095, 4_096)
      refute MM.exceeds?(10, 4_096)
    end

    test "a nil limit disables the ceiling rather than tripping on everything" do
      refute MM.exceeds?(9_000, nil)
      refute MM.exceeds?(0, nil)
    end

    test "a nil measurement never trips" do
      refute MM.exceeds?(nil, 4_096)
    end
  end

  describe "decide/4 — first crossing" do
    test "warns the first time the limit is crossed" do
      state = %MM{}
      assert {:warn, new_state} = MM.decide(state, 5_000, 4_096, 1_000)
      assert new_state.warned? == true
      assert new_state.last_warned_at == 1_000
    end

    test "does nothing while under the limit" do
      state = %MM{}
      assert {:ok, %MM{warned?: false}} = MM.decide(state, 100, 4_096, 1_000)
    end
  end

  describe "decide/4 — rate limiting while sustained above the line" do
    test "does not re-warn immediately on the next tick" do
      state = %MM{warned?: true, last_warned_at: 1_000}
      # 1 second later, still over — well inside the renotify floor.
      assert {:ok, ^state} = MM.decide(state, 5_000, 4_096, 2_000)
    end

    test "re-warns once the renotify floor has elapsed" do
      state = %MM{warned?: true, last_warned_at: 1_000}
      floor = MM.renotify_ms()

      assert {:warn, new_state} = MM.decide(state, 5_000, 4_096, 1_000 + floor)
      assert new_state.last_warned_at == 1_000 + floor
    end

    test "does not re-warn one ms before the renotify floor" do
      state = %MM{warned?: true, last_warned_at: 1_000}
      floor = MM.renotify_ms()

      assert {:ok, _state} = MM.decide(state, 5_000, 4_096, 1_000 + floor - 1)
    end
  end

  describe "decide/4 — re-arming" do
    test "dropping back under the limit re-arms the warned flag" do
      state = %MM{warned?: true, last_warned_at: 1_000}
      assert {:ok, new_state} = MM.decide(state, 100, 4_096, 1_500)
      assert new_state.warned? == false
    end

    test "a fresh crossing after re-arming warns again immediately" do
      state = %MM{warned?: true, last_warned_at: 1_000}
      {:ok, rearmed} = MM.decide(state, 100, 4_096, 1_500)

      assert {:warn, _new_state} = MM.decide(rearmed, 5_000, 4_096, 1_600)
    end
  end

  describe "warning_message/2 — names concrete steps, not just numbers" do
    test "mentions the numbers" do
      msg = MM.warning_message(5_000, 4_096)
      assert msg =~ "5000 MB"
      assert msg =~ "4096 MB"
    end

    test "names concrete remediation steps (finish/stop background work, compact, restart)" do
      msg = MM.warning_message(5_000, 4_096)
      assert msg =~ "background tasks"
      assert msg =~ "/compact" or msg =~ "compact"
      assert msg =~ "restart"
    end
  end

  describe "warn-only: nothing here ever stops a background task" do
    test "the module has no kill/stop-related public function" do
      exported = MM.__info__(:functions) |> Keyword.keys()
      refute :kill in exported
      refute :stop_background in exported
    end
  end

  describe "config defaults" do
    @keys [:daemon_memory_check_ms, :daemon_memory_critical_mb, :daemon_memory_renotify_ms]

    setup do
      previous = Enum.map(@keys, &{&1, Application.fetch_env(:optimal_system_agent, &1)})

      on_exit(fn ->
        Enum.each(previous, fn
          {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
          {k, :error} -> Application.delete_env(:optimal_system_agent, k)
        end)
      end)

      :ok
    end

    test "the default critical threshold is well above healthy usage but far below the host" do
      Application.delete_env(:optimal_system_agent, :daemon_memory_critical_mb)
      limit = MM.critical_mb()

      assert limit > 512, "#{limit} MB would warn on a normal session"
      assert limit < 32_000, "#{limit} MB is too close to exhausting a typical host"
    end

    test "the watchdog can be switched off entirely" do
      Application.put_env(:optimal_system_agent, :daemon_memory_check_ms, nil)
      refute is_integer(MM.check_ms())
    end

    test "the renotify floor is well above the check interval so a sustained excursion does not spam" do
      # The test env pins :daemon_memory_check_ms to nil (config/test.exs) so
      # the watchdog never fires on a timer; delete that override HERE to read
      # the real default the running daemon would use.
      Application.delete_env(:optimal_system_agent, :daemon_memory_check_ms)
      assert MM.renotify_ms() > MM.check_ms()
    end
  end

  describe "measuring the real daemon process" do
    test "beam_mb/0 returns a plausible positive number" do
      mb = MM.beam_mb()
      assert is_integer(mb)
      assert mb > 0
      assert mb < 32_000
    end

    test "rss_mb/0 returns a plausible number or nil on an unsupported platform" do
      case MM.rss_mb() do
        nil -> :ok
        mb -> assert is_integer(mb) and mb > 0 and mb < 32_000
      end
    end

    test "sample/0 never raises" do
      assert %{beam_mb: beam, rss_mb: _rss} = MM.sample()
      assert is_integer(beam)
    end
  end
end
