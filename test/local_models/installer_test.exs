defmodule OptimalSystemAgent.LocalModels.InstallerTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.LocalModels.Installer

  test "a job reports pull progress, then benchmarking, then done with the tag and bench" do
    {:ok, id} =
      Installer.start("fake-ref-#{System.unique_integer([:positive])}", "Q4_K_M", run: false)

    job = Installer.status(id)
    assert %{state: :pulling, status: "starting"} = job

    fake = fn _ref, opts ->
      cb = Keyword.fetch!(opts, :on_progress)
      cb.(%{status: "pulling abc", completed: 50, total: 100})
      assert %{state: :pulling, completed: 50, total: 100} = Installer.status(id)
      cb.(%{status: "success", completed: 100, total: 100})
      assert %{state: :benchmarking} = Installer.status(id)
      {:ok, %{tag: "hf.co/x:Q4_K_M", bench: %{decode_tps: 42.0}}}
    end

    Installer.run(id, job.ref, "Q4_K_M", fake)

    assert %{state: :done, tag: "hf.co/x:Q4_K_M", bench: %{decode_tps: 42.0}} =
             Installer.status(id)

    assert Enum.any?(Installer.list(), &(&1.id == id))
    Installer.forget(id)
    assert Installer.status(id) == nil
  end

  test "a failed pull is reported, and a crash inside the job does not lose it" do
    {:ok, id} = Installer.start("bad-#{System.unique_integer([:positive])}", nil, run: false)
    Installer.run(id, "bad", nil, fn _, _ -> {:error, "no such quant"} end)
    assert %{state: :error, error: "no such quant"} = Installer.status(id)

    {:ok, id2} = Installer.start("boom-#{System.unique_integer([:positive])}", nil, run: false)
    Installer.run(id2, "boom", nil, fn _, _ -> raise "kaboom" end)
    assert %{state: :error, error: "kaboom"} = Installer.status(id2)
  end

  test "the same ref cannot be installed twice at once" do
    ref = "dup-#{System.unique_integer([:positive])}"
    {:ok, _} = Installer.start(ref, nil, run: false)
    assert {:error, msg} = Installer.start(ref, nil, run: false)
    assert msg =~ "already installing"
  end
end
