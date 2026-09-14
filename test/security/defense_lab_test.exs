defmodule OptimalSystemAgent.Security.DefenseLabTest do
  use ExUnit.Case, async: true
  alias OptimalSystemAgent.Security.DefenseLab

  test "invalid inputs never execute Docker" do
    runner = fn _, _ -> flunk("invalid input reached Docker") end

    for args <- [
          nil,
          %{"scenario" => "https://example.com"},
          %{"timeout_seconds" => 61},
          %{"timeout_seconds" => "30"},
          %{"remediation" => "host_patch"}
        ] do
      assert {:error, %{code: _}} = DefenseLab.run(args, runner: runner)
    end
  end

  test "missing image/daemon fails closed" do
    assert {:error, %{code: "prerequisite_missing"}} =
             DefenseLab.run(%{}, runner: fn _, _ -> {:error, "missing"} end)
  end

  test "timeout and process failure still remove the named container" do
    for failure <- [{:error, "Execution timed out"}, {:ok, "failed", 1}] do
      parent = self()

      runner = fn
        ["image" | _], _ ->
          {:ok, "image", 0}

        ["run", "--name", name | _], _ ->
          send(parent, {:run, name})
          failure

        ["rm", "-f", name], _ ->
          send(parent, {:cleanup, name})
          {:ok, name, 0}
      end

      assert {:error, _} = DefenseLab.run(%{}, runner: runner)
      assert_received {:run, name}
      assert_received {:cleanup, ^name}
    end
  end

  test "caller cancellation triggers independent cleanup" do
    parent = self()

    runner = fn
      ["image" | _], _ ->
        {:ok, "", 0}

      ["run", "--name", name | _], _ ->
        send(parent, {:running, name})

        receive do
          :never -> {:ok, "", 0}
        end

      ["rm", "-f", name], _ ->
        send(parent, {:removed, name})
        {:ok, name, 0}
    end

    pid = spawn(fn -> DefenseLab.run(%{}, runner: runner) end)
    assert_receive {:running, name}
    Process.exit(pid, :kill)
    assert_receive {:removed, ^name}, 1000
  end

  test "empty and inconsistent successful reports are rejected" do
    {output, 0} = System.cmd("python3", ["-I", "-c", DefenseLab.script(), "all", "apply"])
    good = Jason.decode!(output)

    for bad <- [
          %{"scenarios" => [], "verified" => true},
          Map.put(good, "verified", false),
          update_in(good, ["scenarios"], fn [first | rest] ->
            [Map.put(first, "verified", false) | rest]
          end),
          update_in(good, ["scenarios"], fn [first | rest] ->
            [Map.put(first, "scenario", "unknown") | rest]
          end)
        ] do
      runner = fn
        ["image" | _], _ -> {:ok, "", 0}
        ["run" | _], _ -> {:ok, Jason.encode!(bad), 0}
        ["rm" | _], _ -> {:ok, "", 0}
      end

      assert {:error, %{code: "invalid_evidence"}} = DefenseLab.run(%{}, runner: runner)
    end
  end

  test "runner exceptions still clean up" do
    parent = self()

    runner = fn
      ["image" | _], _ ->
        {:ok, "", 0}

      ["run" | _], _ ->
        raise "runner failed"

      ["rm" | _], _ ->
        send(parent, :cleaned)
        {:ok, "", 0}
    end

    assert {:error, %{code: "execution_failed"}} = DefenseLab.run(%{}, runner: runner)
    assert_received :cleaned
  end

  test "cleanup failure cannot produce successful evidence" do
    runner = fn
      ["image" | _], _ -> {:ok, "", 0}
      ["run" | _], _ -> {:ok, ~s({"scenarios":[],"verified":true}), 0}
      ["rm" | _], _ -> {:error, "daemon disconnected"}
    end

    assert {:error, %{code: "cleanup_failed"}} = DefenseLab.run(%{}, runner: runner)
  end

  test "malformed evidence is rejected after cleanup" do
    runner = fn
      ["image" | _], _ -> {:ok, "", 0}
      ["run" | _], _ -> {:ok, "not JSON", 0}
      ["rm" | _], _ -> {:ok, "", 0}
    end

    assert {:error, %{code: "invalid_evidence"}} = DefenseLab.run(%{}, runner: runner)
  end

  test "bundled experiments prove real attack and benign outcomes including failed patches" do
    python = System.find_executable("python3")
    assert python, "Python 3 is required to verify the bundled lab fixture"
    # This test executes only repository-owned fixture code. The runtime tool
    # always requires Docker and never takes this host test path.
    for mode <- ~w(apply none ineffective) do
      {output, 0} = System.cmd(python, ["-I", "-c", DefenseLab.script(), "all", mode])
      report = Jason.decode!(output)
      assert length(report["scenarios"]) == 3
      assert report["verified"] == (mode == "apply")

      for result <- report["scenarios"] do
        [baseline, retest] = result["phases"]
        assert baseline["attack_succeeded"]
        assert baseline["benign_control_passed"]
        assert baseline["gaps"] == ["attack_not_prevented", "attack_not_detected"]
        assert retest["benign_control_passed"]
        assert retest["false_alerts"] == 0
        assert retest["attack_succeeded"] == (mode != "apply")
        assert result["verified"] == (mode == "apply")
        assert Enum.any?(baseline["events"], & &1["suspicious"])
      end
    end
  end

  test "run arguments forbid host access and unrestricted resources" do
    args = DefenseLab.docker_args("osa-defense-test", "all", "apply")

    for required <- [
          "--network=none",
          "--read-only",
          "--cap-drop=ALL",
          "--security-opt=no-new-privileges",
          "--user=65534:65534",
          "--pids-limit=32",
          "--pull=never"
        ] do
      assert required in args
    end

    refute Enum.any?(
             args,
             &(&1 in ["--privileged", "-v", "--volume", "--mount", "-p", "--publish"])
           )
  end
end
