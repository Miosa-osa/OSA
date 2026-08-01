defmodule OptimalSystemAgent.Shell.TaskOutputTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Shell.TaskOutput

  test "path/2 lands under tmp/osa/<session>/tasks and sanitizes traversal" do
    p = TaskOutput.path("sess-1", "bg_abc")
    assert String.starts_with?(p, Path.join(System.tmp_dir!(), "osa"))
    assert String.ends_with?(p, "/sess-1/tasks/bg_abc.out")

    evil = TaskOutput.path("../../etc", "bg/../../passwd")
    refute String.contains?(evil, "..")
    assert String.starts_with?(evil, Path.join(System.tmp_dir!(), "osa"))
  end

  test "append/3 creates the file, accumulates chunks; nil session no-ops" do
    # NOTE: `System.unique_integer/1` restarts from scratch on every BEAM boot,
    # so an integer-only session id collides with leftovers from earlier runs
    # and `append/3` then accumulates on top of a stale file. Use a random
    # suffix, and remove the session dir on exit so nothing is left behind.
    sid = "to-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    on_exit(fn -> File.rm_rf(session_dir(sid)) end)

    refute File.exists?(TaskOutput.path(sid, "t1"))

    assert :ok = TaskOutput.append(sid, "t1", "hello ")
    assert :ok = TaskOutput.append(sid, "t1", "world")
    assert File.read!(TaskOutput.path(sid, "t1")) == "hello world"

    assert :ok = TaskOutput.append(nil, "t1", "ignored")
  end

  test "ensure/2 creates the file empty and never truncates an existing one" do
    sid = "to-ensure-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    on_exit(fn -> File.rm_rf(session_dir(sid)) end)

    path = TaskOutput.path(sid, "t1")
    refute File.exists?(path)

    assert :ok = TaskOutput.ensure(sid, "t1")
    assert File.exists?(path), "the advertised output-file must exist from task start"
    assert File.read!(path) == ""

    assert :ok = TaskOutput.append(sid, "t1", "some output")
    # Idempotent — a second ensure must not wipe what the task already wrote.
    assert :ok = TaskOutput.ensure(sid, "t1")
    assert File.read!(path) == "some output"

    assert :ok = TaskOutput.ensure(nil, "t1")
  end

  # `<tmp>/osa/<session>` — the parent of the `tasks/` dir TaskOutput writes into.
  defp session_dir(sid), do: sid |> TaskOutput.path("probe") |> Path.dirname() |> Path.dirname()
end
