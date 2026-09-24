defmodule OptimalSystemAgent.BenchSmokeTest do
  @moduledoc """
  The CI smoke for `mix osa.bench`: every task runs through the real agent
  loop and the real tools, with the mock provider replaying a scripted control.

    * oracle (the task's reference solution) must PASS every task - the task is
      solvable and its checker recognises a correct result;
    * nop (answer immediately, touch nothing) must FAIL every task - the
      checker is not satisfied by the starting state.

  Together these keep the suite honest as tasks are added, and prove the
  harness measures a real turn: every oracle row carries a trace whose tool
  count equals the reference's.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Bench
  alias OptimalSystemAgent.Bench.Report

  @moduletag timeout: 300_000

  setup_all do
    prev = Application.get_env(:optimal_system_agent, :default_provider)
    Application.put_env(:optimal_system_agent, :default_provider, :mock)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :default_provider, prev),
        else: Application.delete_env(:optimal_system_agent, :default_provider)
    end)

    run = fn control ->
      {:ok, doc} =
        Bench.run(
          provider: :mock,
          model: "mock-model-1.0",
          control: control,
          timeout_s: 120
        )

      doc
    end

    %{oracle: run.(:oracle), nop: run.(:nop)}
  end

  test "the suite has 20-30 tasks", %{oracle: doc} do
    assert length(doc.tasks) in 20..30
  end

  test "every task passes under its reference solution", %{oracle: doc} do
    failed =
      doc.tasks
      |> Enum.reject(& &1.pass)
      |> Enum.map(fn r -> {r.id, r.error || Enum.reject(r.checks, & &1.pass)} end)

    assert failed == []
    assert doc.summary.passed_tasks == length(doc.tasks)
  end

  test "every task fails when the agent does nothing", %{nop: doc} do
    assert Enum.filter(doc.tasks, & &1.pass) |> Enum.map(& &1.id) == []
  end

  test "each oracle row is measured from the turn's own trace", %{oracle: doc} do
    for row <- doc.tasks do
      assert row.status == "done"
      assert is_map(row.trace), "#{row.id} has no trace"
      assert row.llm_calls >= 1, "#{row.id} recorded no model call"
      assert row.tool_calls == row.par_tool_calls, "#{row.id}: #{row.tool_calls} vs par"
      assert row.tokens_in > 0
      assert is_integer(row.model_ms) and is_integer(row.tool_ms)
      assert row.wall_ms >= row.model_ms
    end
  end

  test "the result document round-trips and compares", %{oracle: oracle, nop: nop} do
    dir = Path.join(System.tmp_dir!(), "osa-bench-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    Report.write!(Path.join(dir, "a.json"), oracle)
    Report.write!(Path.join(dir, "b.json"), nop)

    {:ok, a} = Report.read(Path.join(dir, "a.json"))
    {:ok, b} = Report.read(Path.join(dir, "b.json"))

    result = Report.compare(a, b)
    assert length(result.summary.regressed) == length(oracle.tasks)
    assert result.text =~ "REGRESSED"

    table = Report.table(oracle.tasks)
    assert table =~ "#{length(oracle.tasks)}/#{length(oracle.tasks)} tasks passed"
  end

  test "the HTTP runner drives the API and reads the turn back from /trace" do
    # Req's in-process `plug:` adapter hands the router a pre-read body, so the
    # HMAC integrity plug (on whenever OSA_SHARED_SECRET is set) cannot see the
    # signed bytes here. Integrity is not what this test is about; switch it off.
    prev =
      Map.new(
        [:require_auth, :shared_secret],
        &{&1, Application.get_env(:optimal_system_agent, &1)}
      )

    Application.put_env(:optimal_system_agent, :require_auth, false)
    Application.delete_env(:optimal_system_agent, :shared_secret)

    on_exit(fn ->
      Enum.each(prev, fn
        {k, nil} -> Application.delete_env(:optimal_system_agent, k)
        {k, v} -> Application.put_env(:optimal_system_agent, k, v)
      end)
    end)

    {:ok, doc} =
      Bench.run(
        only: ["settings-one-line", "large-log-needle"],
        control: :oracle,
        runner: :http,
        url: "http://bench.invalid",
        req_options: [plug: OptimalSystemAgent.Channels.HTTP],
        timeout_s: 60
      )

    for row <- doc.tasks do
      assert row.pass, "#{row.id}: #{inspect(row.error || row.checks)}"
      assert row.tool_calls == row.par_tool_calls
      assert row.llm_calls >= 1
    end

    assert doc.runner == "http"
  end
end
