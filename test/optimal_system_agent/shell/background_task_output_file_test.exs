defmodule OptimalSystemAgent.Shell.BackgroundTaskOutputFileTest do
  @moduledoc """
  The `<output-file>` a `<task-notification>` advertises must EXIST and be
  COMPLETE at the moment the notification is delivered.

  Regression: the file was created lazily by the first `{:data, _}` chunk, so a
  background command that printed nothing advertised a path that was never
  created. The model read it and got
  `cat: …/bg_XXXX.out: No such file or directory` — a notification pointing at
  a missing file, which is worse than no notification at all.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Shell.BackgroundManager
  alias OptimalSystemAgent.Shell.TaskOutput

  defp sid(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false))

  defp session_dir(s), do: s |> TaskOutput.path("probe") |> Path.dirname() |> Path.dirname()

  # Wait for the terminal `:background_command_completed` broadcast and hand
  # back the event exactly as the BackgroundNotifier receives it.
  defp await_completion(session_id) do
    receive do
      {:osa_event, %{type: :background_command_completed} = ev} -> ev
    after
      15_000 -> flunk("no :background_command_completed for #{session_id}")
    end
  end

  setup do
    s = sid("bgout")
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{s}")
    on_exit(fn -> File.rm_rf(session_dir(s)) end)
    {:ok, session: s}
  end

  test "the advertised output-file exists as soon as the task starts", %{session: s} do
    {:ok, id} = BackgroundManager.start("sleep 5", System.tmp_dir!(), session_id: s)

    # No output has been produced yet — the file must exist anyway, because the
    # path is already advertised to the model by the tool result.
    assert File.exists?(TaskOutput.path(s, id)),
           "output-file must exist from task start, before any output"

    {:ok, snap} = BackgroundManager.output(id)
    assert File.exists?(snap.output_file)

    BackgroundManager.kill(id)
  end

  test "a SILENT command's output-file exists when the notification fires", %{session: s} do
    {:ok, id} = BackgroundManager.start("true", System.tmp_dir!(), session_id: s)

    ev = await_completion(s)
    assert ev[:background_id] == id
    assert ev[:exit_code] == 0

    path = ev[:output_file]
    assert is_binary(path)
    assert path == TaskOutput.path(s, id)

    assert File.exists?(path),
           "the notification advertised #{path} but nothing is there"

    assert File.read!(path) == ""
  end

  test "the output-file is COMPLETE when the notification fires", %{session: s} do
    {:ok, _id} =
      BackgroundManager.start(
        "printf 'line1\\nline2\\nline3\\n'",
        System.tmp_dir!(),
        session_id: s
      )

    ev = await_completion(s)
    path = ev[:output_file]

    # Read it the instant the notification lands — no sleep, no retry. The file
    # must already hold the whole stream (port `{:data,_}` messages are handled
    # before `{:exit_status,_}`, and TaskOutput appends are synchronous writes).
    assert File.read!(path) == "line1\nline2\nline3\n"
  end

  test "the advertised path is not doubled or otherwise mangled", %{session: s} do
    {:ok, id} = BackgroundManager.start("echo hi", System.tmp_dir!(), session_id: s)

    ev = await_completion(s)
    path = ev[:output_file]

    tmp = System.tmp_dir!()
    assert String.starts_with?(path, Path.join(tmp, "osa"))
    refute String.contains?(path, "//")
    refute String.contains?(path, "..")
    # A concatenation bug would repeat the tmp prefix (the reported
    # `/var/var/folders/…`); there must be exactly one occurrence.
    assert length(String.split(path, Path.join(tmp, "osa"))) == 2
    assert String.ends_with?(path, "/#{id}.out")
  end
end
