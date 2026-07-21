defmodule OptimalSystemAgent.Agent.DurableWritesAtomicTest do
  @moduledoc """
  Audit gap D4 — the two long-horizon anchors (`PlanStore` plan file and
  `ProgressLedger`'s `## Goal` rewrite) must be written atomically, so a crash
  mid-write can never leave a torn goal/plan file. These are exactly the files a
  long run relies on to recover its intent.

  Atomicity is exercised with concurrent whole-file writers: with a temp+rename
  write, the final file is always ONE writer's complete content (never a torn
  interleaving of two). No `.tmp` turds are left behind.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.PlanStore
  alias OptimalSystemAgent.Agent.ProgressLedger

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_atomic_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prev_home = Application.get_env(:optimal_system_agent, :config_dir)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)

    on_exit(fn ->
      case prev_home do
        nil -> Application.delete_env(:optimal_system_agent, :config_dir)
        v -> Application.put_env(:optimal_system_agent, :config_dir, v)
      end

      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, session: "atomic_#{System.unique_integer([:positive])}"}
  end

  describe "PlanStore.write_plan_file/2 atomicity" do
    test "writes and re-reads intact", %{session: session} do
      assert :ok = PlanStore.write_plan_file(session, "### Plan\nstep one\n")
      assert {:ok, "### Plan\nstep one\n"} = PlanStore.read_plan_file(session)
    end

    test "concurrent whole-file writers leave exactly one intact plan, no torn file", %{
      session: session
    } do
      contents = for i <- 1..24, do: "### Plan #{i}\n" <> String.duplicate("body #{i}\n", 200)

      contents
      |> Enum.map(fn c -> Task.async(fn -> PlanStore.write_plan_file(session, c) end) end)
      |> Enum.each(&Task.await(&1, 5_000))

      assert {:ok, final} = PlanStore.read_plan_file(session)
      # The final file is byte-identical to ONE of the writers' full contents —
      # never a spliced/torn mix.
      assert final in contents
    end

    test "no leftover .tmp files after writes", %{tmp: tmp, session: session} do
      PlanStore.write_plan_file(session, "x")
      leftovers = tmp |> Path.join("sessions") |> list_tmp()
      assert leftovers == []
    end
  end

  describe "ProgressLedger.set_goal/2 rewrite atomicity" do
    test "sets and reads back the goal", %{session: session} do
      assert {:ok, "My goal"} = ProgressLedger.set_goal(session, "My goal")
      assert {:ok, contents} = ProgressLedger.read(session)
      assert contents =~ "## Goal\n\nMy goal\n\n## Log"
    end

    test "concurrent goal rewrites never tear the file (valid structure, one goal wins)", %{
      session: session
    } do
      # Seed the ledger so all writers do a full-file rewrite of the same file.
      {:ok, _} = ProgressLedger.set_goal(session, "seed")

      goals = for i <- 1..24, do: "goal-#{i}"

      goals
      |> Enum.map(fn g -> Task.async(fn -> ProgressLedger.set_goal(session, g) end) end)
      |> Enum.each(&Task.await(&1, 5_000))

      assert {:ok, contents} = ProgressLedger.read(session)

      # Structure intact (never torn): both required section headers present, and
      # the Goal body is exactly one of the concurrently-written goals (or seed).
      assert contents =~ "## Goal"
      assert contents =~ "## Log"

      goal_body =
        case Regex.run(~r/## Goal\n\n(.*?)\n\n## Log/s, contents) do
          [_full, body] -> String.trim(body)
          _ -> :no_match
        end

      assert goal_body in (goals ++ ["seed"])
    end

    test "append_entry stays append-only (replay semantics preserved)", %{session: session} do
      {:ok, _} = ProgressLedger.set_goal(session, "g")
      {:ok, _} = ProgressLedger.append_entry(session, "first")
      {:ok, _} = ProgressLedger.append_entry(session, "second")

      assert {:ok, contents} = ProgressLedger.read(session)
      first_at = :binary.match(contents, "first") |> elem(0)
      second_at = :binary.match(contents, "second") |> elem(0)
      # Appends preserve chronological order in the Log section.
      assert first_at < second_at
    end

    test "no leftover .tmp files after a goal rewrite", %{tmp: tmp, session: session} do
      {:ok, _} = ProgressLedger.set_goal(session, "g1")
      {:ok, _} = ProgressLedger.set_goal(session, "g2")
      leftovers = tmp |> Path.join("sessions") |> list_tmp()
      assert leftovers == []
    end
  end

  defp list_tmp(dir) do
    case File.ls(dir) do
      {:ok, files} -> Enum.filter(files, &String.contains?(&1, ".tmp."))
      _ -> []
    end
  end
end
