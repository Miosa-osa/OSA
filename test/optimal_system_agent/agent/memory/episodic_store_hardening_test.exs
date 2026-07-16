defmodule OptimalSystemAgent.Agent.Memory.EpisodicStoreHardeningTest do
  @moduledoc """
  Regression test for the atomic-write hardening of EpisodicStore.append/2
  (finding 21). A crash mid-write previously truncated the whole session's
  episode array (read_file then silently returns [] on garbage, losing every
  prior episode). Atomic temp+rename closes the torn-file window.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Memory.EpisodicStore

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_episodic_hard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:optimal_system_agent, :episodic_dir)
    Application.put_env(:optimal_system_agent, :episodic_dir, tmp)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :episodic_dir, prev),
        else: Application.delete_env(:optimal_system_agent, :episodic_dir)

      File.rm_rf(tmp)
    end)

    {:ok, dir: tmp, session: "sess_#{System.unique_integer([:positive])}"}
  end

  test "record persists episodes and leaves no .tmp behind", %{dir: dir, session: session} do
    assert {:ok, _} = EpisodicStore.record(session, %{task: "first task", outcome: "success"})
    assert {:ok, _} = EpisodicStore.record(session, %{task: "second task", outcome: "success"})

    # Both episodes survive the read-modify-write append (no truncation).
    episodes = EpisodicStore.list(session)
    assert length(episodes) == 2

    # Atomic rename leaves the sibling temp file cleaned up.
    tmps = File.ls!(dir) |> Enum.filter(&String.ends_with?(&1, ".tmp"))
    assert tmps == []
  end
end
