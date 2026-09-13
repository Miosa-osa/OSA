defmodule OptimalSystemAgent.Security.EntryFanoutTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.CiScan
  alias OptimalSystemAgent.Security.EntryFanout

  setup do
    root = Path.join(System.tmp_dir!(), "osa-fanout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "router.ex"),
      "defmodule R do\n  def show(id), do: Repo.query(\"select \" <> id)\nend\n"
    )

    File.write!(
      Path.join(root, "users_api.py"),
      "from fastapi import APIRouter\nr = APIRouter()\n"
    )

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "plan returns CiScan entries including router.ex", %{root: root} do
    assert {:ok, tasks} = EntryFanout.plan(root)
    bases = Enum.map(tasks, &Path.basename(&1.entry))
    discovered = CiScan.discover_entries(root) |> Enum.map(&Path.basename/1)

    assert "router.ex" in bases
    assert "router.ex" in discovered

    for name <- discovered do
      assert name in bases
    end
  end

  test "max: 1 returns 1 task", %{root: root} do
    assert {:ok, tasks} = EntryFanout.plan(root, max: 1)
    assert length(tasks) == 1
  end

  test "missing root errors" do
    assert {:error, reason} = EntryFanout.plan("/no/such/osa-fanout")
    assert is_binary(reason)
    assert reason =~ "root"
  end

  test "each prompt mentions the entry basename and each subagent_type is security-auditor", %{
    root: root
  } do
    assert {:ok, tasks} = EntryFanout.plan(root)
    assert tasks != []

    for task <- tasks do
      assert task.subagent_type == "security-auditor"
      assert task.prompt =~ Path.basename(task.entry)
      assert task.prompt =~ "only this entry file and symbols it calls"
      assert task.prompt =~ "One vuln class at a time"
      assert task.prompt =~ "IDOR"
      assert task.prompt =~ "next symbol AND the exact line"
      assert task.prompt =~ "Confidence 0-10"
      assert task.prompt =~ "cap at 6"
      assert task.prompt =~ "Do not confirm your own finding"
      assert task.prompt =~ "not assessed, not clean"
      assert task.prompt =~ "Do not invent RoE"
      refute task.prompt =~ "Rules of Engagement:"
      assert is_binary(task.success_criteria)
      assert task.success_criteria != ""
    end
  end

  test "delegate_payload has tasks list of the same length", %{root: root} do
    assert {:ok, tasks} = EntryFanout.plan(root)
    payload = EntryFanout.delegate_payload(tasks)
    assert is_list(payload["tasks"])
    assert length(payload["tasks"]) == length(tasks)

    for item <- payload["tasks"] do
      assert is_binary(item["prompt"])
      assert item["subagent_type"] == "security-auditor"
    end
  end

  test "render is a numbered list of entries and role", %{root: root} do
    assert {:ok, tasks} = EntryFanout.plan(root)
    text = EntryFanout.render(tasks)
    assert text =~ "1."
    assert text =~ "router.ex"
    assert text =~ "security-auditor"
  end

  test "recipe JSON exists, decodes, and has name plus at least 3 steps" do
    path = Path.expand("../../priv/recipes/whitebox-entry-fanout.json", __DIR__)
    assert File.exists?(path)
    assert {:ok, raw} = File.read(path)
    assert {:ok, recipe} = Jason.decode(raw)
    assert is_binary(recipe["name"]) and recipe["name"] != ""
    assert is_list(recipe["steps"])
    assert length(recipe["steps"]) >= 3

    {exec, rest} = Enum.split(recipe["steps"], 3)
    assert Enum.all?(exec, &(&1["signal_mode"] == "EXECUTE"))
    assert rest != []
    assert List.last(recipe["steps"])["signal_mode"] == "ASSIST"
  end
end
