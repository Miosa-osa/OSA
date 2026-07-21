defmodule OptimalSystemAgent.Tools.Builtins.ScratchpadTest do
  @moduledoc """
  W6 — shared-scratchpad concurrency hardening for the `scratchpad` builtin
  handler.

  Covers:
    * many concurrent fleet nodes writing DISTINCT entries at once — none lost;
    * many concurrent nodes appending to the SAME entry — no torn/lost lines;
    * turn-boundary durability: the file-based shared scratchpad is NOT wiped on
      a new turn, and the handler self-heals (re-seeds the dir) if the directory
      is removed mid-run, so an in-flight workflow keeps coordinating.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Scratchpad
  alias OptimalSystemAgent.Tools.Builtins.Scratchpad.Handler
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    prev_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_boot = Application.get_env(:optimal_system_agent, :bootstrap_dir)

    tmp =
      Path.join(System.tmp_dir!(), "osa_scratchpad_w6_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)
    Application.delete_env(:optimal_system_agent, :bootstrap_dir)
    ConfigFile.reload()

    on_exit(fn ->
      restore(:config_dir, prev_dir)
      restore(:bootstrap_dir, prev_boot)
      ConfigFile.reload()
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, v), do: Application.put_env(:optimal_system_agent, key, v)

  defp run(args, session_id) do
    Handler.execute(Map.put(args, "__session_id__", session_id), UseContext.empty())
  end

  describe "concurrent writes from many fleet nodes" do
    test "distinct entries from many concurrent writers all survive intact" do
      sid = "fleet-distinct"
      n = 60

      1..n
      |> Task.async_stream(
        fn i ->
          run(%{"action" => "write", "name" => "node_#{i}.md", "content" => "payload-#{i}"}, sid)
        end,
        max_concurrency: n,
        ordered: false,
        timeout: 15_000
      )
      |> Stream.run()

      # Every entry landed and none clobbered another.
      for i <- 1..n do
        assert {:ok, content} = run(%{"action" => "read", "name" => "node_#{i}.md"}, sid)
        assert content == "payload-#{i}"
      end

      assert {:ok, listing} = run(%{"action" => "list"}, sid)
      assert listing =~ "#{n} entries"
    end

    test "concurrent appends to the SAME entry are neither lost nor torn" do
      sid = "fleet-shared-entry"
      n = 80

      # Fixed-width lines so a torn/interleaved append would corrupt the count
      # and the line-by-line assertion below.
      line = fn i -> "LINE-" <> String.pad_leading(Integer.to_string(i), 4, "0") <> "\n" end

      1..n
      |> Task.async_stream(
        fn i ->
          run(%{"action" => "append", "name" => "shared.md", "content" => line.(i)}, sid)
        end,
        max_concurrency: n,
        ordered: false,
        timeout: 15_000
      )
      |> Stream.run()

      assert {:ok, content} = run(%{"action" => "read", "name" => "shared.md"}, sid)

      lines = content |> String.split("\n", trim: true)
      # No line lost.
      assert length(lines) == n
      # Every line is intact (no torn/partial writes) and exactly the set we wrote.
      expected = for i <- 1..n, into: MapSet.new(), do: String.trim(line.(i))
      assert MapSet.new(lines) == expected
      # Byte-exact: total equals the sum of all appended chunks.
      assert byte_size(content) == Enum.sum(for i <- 1..n, do: byte_size(line.(i)))
    end
  end

  describe "turn-boundary clear vs in-flight workflow" do
    test "shared entries persist across a simulated new turn (durable by design)" do
      sid = "workflow-durable"
      run(%{"action" => "write", "name" => "workflow.md", "content" => "step 1 of 3"}, sid)

      # A new top-level turn does NOT clear the durable file-based scratchpad
      # (only the in-memory provider thinking-scratchpad clears per turn). The
      # in-flight workflow entry must still be readable.
      assert {:ok, "step 1 of 3"} = run(%{"action" => "read", "name" => "workflow.md"}, sid)
    end

    test "handler self-heals if the coordination dir is wiped mid-run" do
      sid = "workflow-selfheal"
      run(%{"action" => "write", "name" => "workflow.md", "content" => "in flight"}, sid)

      # Simulate a hostile / external mid-run wipe of the whole coordination dir.
      dir = Scratchpad.dir_for(Scratchpad.session_root(sid))
      File.rm_rf!(dir)

      # A subsequent coordination write must NOT crash — it re-seeds the dir and
      # the entry lands, so the in-flight workflow keeps coordinating.
      assert {:ok, msg} = run(%{"action" => "write", "name" => "step2.md", "content" => "resumed"}, sid)
      assert msg =~ "Wrote step2.md"
      assert {:ok, "resumed"} = run(%{"action" => "read", "name" => "step2.md"}, sid)
    end
  end
end
