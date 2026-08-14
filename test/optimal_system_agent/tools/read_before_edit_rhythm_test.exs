defmodule OptimalSystemAgent.Tools.ReadBeforeEditRhythmTest do
  @moduledoc """
  Read-before-edit: what is enforced, what is merely advised, and where the
  advice was wrong.

  ## The claim this test set was written to check

  It was believed that OSA enforces read-before-edit in three places and that the
  combination makes `read → edit → read → edit` *mandatory* — the designed rhythm
  behind 66 write operations on one artefact against codex's 12.

  Measured, that is only half true, and the two halves want opposite treatment:

    * **Enforcement does not force a re-read.** `FileState.check_read/2` passes
      after `record_write/2`, so N consecutive edits with no read between them
      all succeed. The `enforcement is unchanged by this change-set` block pins
      that, along with the two rejections that are the guard genuinely working.
    * **The advice did force one, and on no evidence.** The read-before-write
      nudge keyed on a table populated only by `file_read`. Writing a file did
      not count. So `file_write` a new file, then edit it, and the model was told
      "you're modifying <path> without reading it first" about a file it had just
      composed — twice, up to the per-file nudge cap. That is the rhythm being
      *instructed*, and it is what changed.

  Nothing here weakens a staleness property: the nudge is advisory, and the
  rejections below are produced by `FileState` + `DriftGuard`, which are
  untouched.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Hooks.Handlers
  alias OptimalSystemAgent.Agent.Loop.ToolExecutor
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEdit
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileRead
  alias OptimalSystemAgent.Tools.Builtins.FileWrite.Handler, as: FileWrite
  alias OptimalSystemAgent.Tools.FileState
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    FileState.reset()
    sid = "rbe-#{System.unique_integer([:positive])}"

    try do
      :ets.match_delete(:osa_files_read, {{sid, :_}, :_})
    rescue
      ArgumentError -> :ok
    end

    ctx = %UseContext{session_id: sid, permission_tier: :full}
    path = Path.join(System.tmp_dir!(), "osa_rbe_#{System.unique_integer([:positive])}.txt")
    on_exit(fn -> File.rm(path) end)
    {:ok, ctx: ctx, sid: sid, path: path}
  end

  defp edit(path, ctx, old, new),
    do: FileEdit.execute(%{"path" => path, "old_string" => old, "new_string" => new}, ctx)

  # The post-tool-use hook that records "this session has a basis for this
  # file's contents", driven exactly as the loop drives it.
  defp record_tool_use(sid, tool, args, result) do
    {:ok, _} =
      Handlers.track_files_read(%{
        tool_name: tool,
        arguments: args,
        session_id: sid,
        result: result
      })

    :ok
  end

  defp nudged?(sid, path) do
    {:ok, payload} =
      Handlers.read_before_write(%{
        tool_name: "file_edit",
        arguments: %{"path" => path},
        session_id: sid
      })

    Map.has_key?(payload, :nudge)
  end

  defp system_message_injected?(sid, path) do
    state = %{session_id: sid, messages: []}
    tc = %{id: "tc-1", name: "file_edit", arguments: %{"path" => path}}
    ToolExecutor.inject_read_nudges(state, [tc]).messages != []
  end

  describe "enforcement is unchanged by this change-set" do
    test "four consecutive edits with no read between them all succeed",
         %{ctx: ctx, path: path} do
      File.write!(path, Enum.map_join(1..6, "", fn i -> "line#{i}\n" end))
      {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

      for i <- 1..4 do
        result = edit(path, ctx, "line#{i}\n", "LINE#{i}\n")

        assert :ok == elem(result, 0),
               "edit #{i} of 4 was rejected with no read between edits: #{inspect(result)}"
      end

      assert File.read!(path) =~ "LINE4"
    end

    test "an edit to a file changed on disk by someone else is still refused",
         %{ctx: ctx, path: path} do
      File.write!(path, "alpha\nbeta\n")
      {:ok, _} = FileRead.execute(%{"path" => path}, ctx)

      # A second-resolution mtime has to actually move for the guard's coarse
      # check to see it; this is the real-world case (a linter on save).
      :timer.sleep(1100)
      File.write!(path, "alpha\nbeta\ngamma\n")

      assert {:error, msg} = edit(path, ctx, "beta", "BETA")
      assert msg =~ "changed on disk since you last read it"
    end

    test "an edit to a file this session has neither read nor written is still refused",
         %{ctx: ctx, path: path} do
      File.write!(path, "alpha\n")

      assert {:error, msg} = edit(path, ctx, "alpha", "ALPHA")
      assert msg =~ "must read"
    end
  end

  describe "authoring a file counts as a basis for its contents" do
    test "writing a file then editing it does not draw a read-before-write nudge",
         %{ctx: ctx, sid: sid, path: path} do
      assert nudged?(sid, path) == false, "no file yet — nothing to nudge about"

      result = FileWrite.execute(%{"path" => path, "content" => "alpha\nbeta\n"}, ctx)
      assert :ok == elem(result, 0)
      record_tool_use(sid, "file_write", %{"path" => path}, elem(result, 1))

      refute nudged?(sid, path),
             "the model composed this file one turn ago; telling it to go and read the file " <>
               "back is the read->edit->read->edit rhythm being instructed"

      refute system_message_injected?(sid, path)
    end

    test "editing a file then editing it again does not draw a nudge",
         %{ctx: ctx, sid: sid, path: path} do
      File.write!(path, "alpha\nbeta\n")
      {:ok, out} = FileRead.execute(%{"path" => path}, ctx)
      record_tool_use(sid, "file_read", %{"path" => path}, out)

      result = edit(path, ctx, "beta", "BETA")
      assert :ok == elem(result, 0)
      record_tool_use(sid, "file_edit", %{"path" => path}, elem(result, 1))

      refute nudged?(sid, path)
    end

    test "a file neither read nor written is still nudged", %{sid: sid, path: path} do
      File.write!(path, "alpha\n")

      assert nudged?(sid, path)
      assert system_message_injected?(sid, path)
    end

    test "a failed tool call is not a basis for the file's contents",
         %{sid: sid, path: path} do
      File.write!(path, "alpha\n")

      # `ToolError.model_text/1` guarantees this prefix for every non-fatal
      # failure. A rejected edit must not mark the file as known.
      record_tool_use(sid, "file_edit", %{"path" => path}, "Error: old_string not found")

      assert nudged?(sid, path)
    end
  end

  describe "the nudge text tells the model the rule, not a superstition" do
    test "it says read once before the FIRST edit, and not to re-read after its own",
         %{sid: sid, path: path} do
      File.write!(path, "alpha\n")

      {:ok, payload} =
        Handlers.read_before_write(%{
          tool_name: "file_edit",
          arguments: %{"path" => path},
          session_id: sid
        })

      nudge = payload.nudge
      assert nudge =~ "once before this first edit"
      assert nudge =~ "do NOT need to read it again after your own successful edits"
      # The old text said "Always call file_read before file_edit/file_write on
      # existing files", which is the instruction that produced the rhythm.
      refute nudge =~ "Always call file_read"
    end
  end
end
