defmodule OptimalSystemAgent.Agent.DebateLeakTest do
  @moduledoc """
  D8 — `Debate.call_providers/4` dropped timed-out `Task.async` results with no
  `Task.shutdown/2` and no cancel-flag check.

  `Task.yield_many/2` only stops WAITING; the task keeps running. A slow
  provider call therefore outlived the debate that started it — holding its
  connection and spending tokens with nobody to receive the answer — and,
  because `Task.async` links, could still bring the caller down later with an
  exit it was no longer expecting.

  Separately, `call_provider/3` returned `{:provider_unavailable, _}` for every
  non-mock provider, so `Debate.run/2` could only ever FAIL in production while
  `POST /debate` advertised it as a feature. That path is now wired to
  `Providers.Registry.chat/2`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalSystemAgent.Agent.Debate

  @cancel_table :osa_cancel_flags

  setup do
    if :ets.whereis(@cancel_table) == :undefined do
      :ets.new(@cancel_table, [:named_table, :public, read_concurrency: true])
    end

    :ok
  end

  describe "timed-out provider tasks are reaped" do
    test "a provider that never returns is killed, not orphaned" do
      parent = self()

      hang = fn provider, _message ->
        send(parent, {:started, provider, self()})
        Process.sleep(:infinity)
      end

      capture_log(fn ->
        assert {:error, :all_providers_failed} =
                 Debate.run("question", providers: ["slowco"], timeout: 100, provider_call: hang)
      end)

      assert_received {:started, "slowco", task_pid}

      # Give the brutal_kill a beat to land.
      ref = Process.monitor(task_pid)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, _}, 2_000

      refute Process.alive?(task_pid),
             "the timed-out provider task was left running — connection and tokens leak"
    end

    test "every hung task in a multi-provider debate is reaped" do
      parent = self()

      hang = fn provider, _message ->
        send(parent, {:started, provider, self()})
        Process.sleep(:infinity)
      end

      capture_log(fn ->
        Debate.run("q", providers: ["a", "b", "c"], timeout: 100, provider_call: hang)
      end)

      pids =
        for _ <- 1..3 do
          assert_received {:started, _p, pid}
          pid
        end

      Enum.each(pids, fn pid ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      end)
    end

    test "a fast provider still returns its answer" do
      quick = fn provider, _msg -> {:ok, "answer from #{provider}"} end

      assert {:ok, %{synthesis: synthesis, participants: 1}} =
               Debate.run("q", providers: ["fast"], timeout: 2_000, provider_call: quick)

      assert synthesis =~ "answer from fast"
    end
  end

  describe "session cancel is honoured" do
    test "a cancelled session aborts the debate and kills its provider tasks" do
      session = "debate-cancel-#{:erlang.unique_integer([:positive])}"
      :ets.insert(@cancel_table, {session, true})

      parent = self()

      hang = fn provider, _message ->
        send(parent, {:started, provider, self()})
        Process.sleep(:infinity)
      end

      result =
        capture_log(fn ->
          send(
            parent,
            {:result,
             Debate.run("q",
               providers: ["x"],
               timeout: 100,
               session_id: session,
               provider_call: hang
             )}
          )
        end)

      assert is_binary(result)
      assert_received {:result, {:error, :cancelled}}
      assert_received {:started, "x", pid}

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      :ets.delete(@cancel_table, session)
    end

    test "an uncancelled session is unaffected" do
      session = "debate-live-#{:erlang.unique_integer([:positive])}"
      quick = fn p, _m -> {:ok, "ok from #{p}"} end

      assert {:ok, _} =
               Debate.run("q",
                 providers: ["p"],
                 timeout: 2_000,
                 session_id: session,
                 provider_call: quick
               )
    end
  end

  describe "the non-mock path is wired, not stubbed" do
    test "a real provider name reaches the provider registry" do
      log =
        capture_log(fn ->
          Debate.run("hello", providers: ["ollama"], timeout: 5_000)
        end)

      refute log =~ "provider_unavailable",
             "every non-mock provider still short-circuits to {:provider_unavailable, _} — " <>
               "Debate.run/2 can only fail in production"
    end

    test "an unknown provider name gets the registry's own honest error" do
      log =
        capture_log(fn ->
          assert {:error, :all_providers_failed} =
                   Debate.run("hello", providers: ["no_such_provider_xyz"], timeout: 5_000)
        end)

      refute log =~ "provider_unavailable"
      assert log =~ "Unknown provider"
    end

    test "the mock provider still short-circuits deterministically" do
      assert {:ok, %{synthesis: synthesis}} =
               Debate.run("2+2?", providers: ["mock"], timeout: 2_000)

      assert synthesis =~ "Mock response"
    end
  end
end
