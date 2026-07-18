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
    sid = "to-test-" <> Integer.to_string(System.unique_integer([:positive]))
    assert :ok = TaskOutput.append(sid, "t1", "hello ")
    assert :ok = TaskOutput.append(sid, "t1", "world")
    assert File.read!(TaskOutput.path(sid, "t1")) == "hello world"

    assert :ok = TaskOutput.append(nil, "t1", "ignored")
  end
end
