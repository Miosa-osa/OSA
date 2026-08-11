defmodule OptimalSystemAgent.NullConfigKeyTest do
  @moduledoc """
  `Map.get(m, k, default)` does not defend against a present-but-null key.

  The default only fires when the key is ABSENT. Every one of these maps is
  decoded from user-editable JSON or from agent state where an explicit `null`
  is a real shape — the residue an editor leaves when a block is cleared, or a
  field a partial writer never filled in. In each case the nil then flowed into
  code that assumes a collection.

  The `session_persistence` sites are the dangerous ones: they gate what gets
  WRITTEN, and the merge one sits inside the branch whose entire job is to not
  lose a concurrent writer's messages.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.SessionPersistence

  describe "Machines config with an explicit null \"machines\"" do
    setup do
      prev = Application.fetch_env(:optimal_system_agent, :config_dir)
      dir = Path.join(System.tmp_dir!(), "osa-null-cfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:optimal_system_agent, :config_dir, dir)

      on_exit(fn ->
        case prev do
          {:ok, v} -> Application.put_env(:optimal_system_agent, :config_dir, v)
          :error -> Application.delete_env(:optimal_system_agent, :config_dir)
        end

        File.rm_rf(dir)
      end)

      {:ok, dir: dir}
    end

    # Started unnamed so the app's own supervised Machines process is untouched.
    defp boot_machines(dir, config) do
      File.write!(Path.join(dir, "config.json"), Jason.encode!(config))
      {:ok, pid} = GenServer.start(OptimalSystemAgent.Machines, :ok)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      pid
    end

    # `:core` is unconditional (`[:core | enabled]`), so "no machines
    # configured" is exactly `[:core]` — the same answer an absent key gives.
    test "boots with only :core instead of raising", %{dir: dir} do
      pid = boot_machines(dir, %{"machines" => nil})
      assert GenServer.call(pid, :active) == [:core]
    end

    test "an absent key gives the same answer", %{dir: dir} do
      pid = boot_machines(dir, %{})
      assert GenServer.call(pid, :active) == [:core]
    end

    test "a populated map is unaffected", %{dir: dir} do
      pid = boot_machines(dir, %{"machines" => %{"no_such_machine_xyz" => true}})
      # Unknown names are dropped by String.to_existing_atom/1 — the point is
      # only that the non-null path still works and does not raise.
      assert is_list(GenServer.call(pid, :active))
    end
  end

  describe "SessionPersistence" do
    setup do
      prev = Application.fetch_env(:optimal_system_agent, :config_dir)
      root = Path.join(System.tmp_dir!(), "osa-null-sess-#{System.unique_integer([:positive])}")
      dir = Path.join(root, "sessions")
      File.mkdir_p!(dir)
      Application.put_env(:optimal_system_agent, :config_dir, root)

      on_exit(fn ->
        case prev do
          {:ok, v} -> Application.put_env(:optimal_system_agent, :config_dir, v)
          :error -> Application.delete_env(:optimal_system_agent, :config_dir)
        end

        File.rm_rf(root)
      end)

      {:ok, dir: dir}
    end

    test "save_from_state/2 tolerates a present-but-nil :messages" do
      session = "null-messages-#{System.unique_integer([:positive])}"

      # `:messages` is PRESENT and nil, so `Map.get(state, :messages, [])`
      # returns nil rather than the `[]` default, and `save/3`'s
      # `when is_list(messages)` head no longer matches.
      assert :ok =
               SessionPersistence.save_from_state(session, %{
                 messages: nil,
                 working_dir: File.cwd!()
               })
    end

    test "save_from_state/2 still persists a real message list" do
      session = "real-messages-#{System.unique_integer([:positive])}"

      assert :ok =
               SessionPersistence.save_from_state(session, %{
                 messages: [%{role: "user", content: "hello"}],
                 working_dir: File.cwd!()
               })
    end

    test "the concurrent-writer merge survives an on-disk \"messages\": null", %{dir: dir} do
      session = "null-ondisk-#{System.unique_integer([:positive])}"

      # 1. A normal save, so this VM has an observed rev for the session — the
      #    precondition for `reconcile/3` to treat a differing on-disk rev as a
      #    conflict rather than a plain overwrite.
      assert :ok = SessionPersistence.save(session, [%{role: "user", content: "first"}])

      # 2. A "foreign writer" leaves a record whose rev has moved on and whose
      #    messages key is an explicit null. Truncated/partial writes and
      #    hand-edited session files both produce this.
      path = Path.join(dir, "#{session}.json")
      record = path |> File.read!() |> Jason.decode!()

      File.write!(
        path,
        Jason.encode!(%{record | "rev" => (record["rev"] || 0) + 5, "messages" => nil})
      )

      # 3. Our next save takes the merge branch, where `Map.get(existing,
      #    "messages", [])` returned nil straight into Enum.filter/2.
      assert :ok = SessionPersistence.save(session, [%{role: "user", content: "second"}])

      reloaded = path |> File.read!() |> Jason.decode!()
      assert is_list(reloaded["messages"])
    end
  end
end
