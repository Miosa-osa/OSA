defmodule OptimalSystemAgent.Tools.BashOutputWaitTest do
  @moduledoc """
  `bash_output` must be able to WAIT.

  Until it could, the harness had no way for an agent to observe a background
  command's result inside the turn that started it. The tool returned instantly,
  its own prompt said "DO NOT USE THIS TOOL TO WAIT", `shell_execute` forbade
  `sleep` and re-checking, and the only sanctioned path to the result was a
  completion notification that requires something to drive another turn — which
  nothing does in a one-shot or headless run.

  The measured consequence is `docs/research/failure-taxonomy.md` §1: ten
  Terminal-Bench episodes whose last words were a promise to report a result
  later. The verification gate can refuse such a claim, but a refusal is only
  worth having if the turn has somewhere to go; this is that somewhere.

  These tests drive REAL background commands through the real
  `Shell.BackgroundManager`, so they check the mechanism rather than a mock of
  it. No provider is involved.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Shell.BackgroundManager
  alias OptimalSystemAgent.Tools.Builtins.BashOutput.Handler

  setup do
    sid = "bgwait-#{System.unique_integer([:positive])}"
    {:ok, session_id: sid, ctx: %{session_id: sid}}
  end

  defp start_bg(cmd, sid) do
    {:ok, id} = BackgroundManager.start(cmd, System.tmp_dir!(), session_id: sid)
    id
  end

  test "wait_ms blocks until the command finishes and returns its real result",
       %{session_id: sid, ctx: ctx} do
    id = start_bg("sleep 1; echo WAITED_MARKER; exit 0", sid)

    # Without waiting the tool can only report "running" — which is exactly the
    # non-answer the ten failed episodes ended on.
    {:ok, immediate} = Handler.execute(%{"background_id" => id}, ctx)
    assert immediate =~ "is running"
    # The marker appears in the echoed `- Command:` line either way; what must
    # be absent is any OUTPUT, which is the thing the model needs and does not
    # have.
    assert immediate =~ "(no output yet)"
    refute immediate =~ "Exit code"

    {:ok, waited} = Handler.execute(%{"background_id" => id, "wait_ms" => 30_000}, ctx)

    assert waited =~ "is done"
    assert waited =~ "Exit code: 0"
    assert waited =~ "WAITED_MARKER"
    assert waited =~ "Waited"
  end

  test "a non-zero exit is reported as failed, not masked", %{session_id: sid, ctx: ctx} do
    id = start_bg("sleep 1; echo BOOM; exit 3", sid)

    {:ok, out} = Handler.execute(%{"background_id" => id, "wait_ms" => 30_000}, ctx)

    assert out =~ "is failed"
    assert out =~ "Exit code: 3"
    assert out =~ "BOOM"
  end

  test "an elapsed wait says so in as many words instead of implying a result",
       %{session_id: sid, ctx: ctx} do
    id = start_bg("sleep 60", sid)

    {:ok, out} = Handler.execute(%{"background_id" => id, "wait_ms" => 300}, ctx)

    assert out =~ "is running"
    assert out =~ "STILL RUNNING"
    assert out =~ "This is not a result"

    {:ok, _} = Handler.execute(%{"background_id" => id, "kill" => true}, ctx)
  end

  test "no wait_ms is byte-identical to the old immediate snapshot",
       %{session_id: sid, ctx: ctx} do
    id = start_bg("sleep 60", sid)

    {:ok, out} = Handler.execute(%{"background_id" => id}, ctx)
    refute out =~ "Waited"

    {:ok, _} = Handler.execute(%{"background_id" => id, "kill" => true}, ctx)
  end

  test "wait_ms is clamped, and a junk value is not a wait", %{session_id: sid, ctx: ctx} do
    id = start_bg("sleep 60", sid)

    # A string wait_ms (providers stringify arguments) is honoured.
    {:ok, out} = Handler.execute(%{"background_id" => id, "wait_ms" => "250"}, ctx)
    assert out =~ "Waited"

    # Junk, zero and negatives mean "do not wait" rather than raising.
    for junk <- [0, -1, "soon", nil, %{}] do
      {:ok, o} = Handler.execute(%{"background_id" => id, "wait_ms" => junk}, ctx)
      refute o =~ "Waited", "wait_ms=#{inspect(junk)} should not have waited"
    end

    {:ok, _} = Handler.execute(%{"background_id" => id, "kill" => true}, ctx)
  end

  test "waiting on an unknown id does not hang", %{ctx: ctx} do
    task =
      Task.async(fn ->
        Handler.execute(%{"background_id" => "bg_nope", "wait_ms" => 30_000}, ctx)
      end)

    assert {:ok, msg} = Task.await(task, 5_000)
    assert msg =~ "No background command with id"
  end

  test "the tool advertises wait_ms in its schema" do
    props = OptimalSystemAgent.Tools.Builtins.BashOutput.Tool.parameters()["properties"]
    assert %{"type" => "integer"} = props["wait_ms"]
  end

  test "the prompt no longer forbids the only way to wait" do
    prompt = OptimalSystemAgent.Tools.Builtins.BashOutput.Prompt.render([])

    refute prompt =~ "DO NOT USE THIS TOOL TO WAIT"
    assert prompt =~ "wait_ms"
    # And it must not promise a notification unconditionally — that promise is
    # what §1 of the taxonomy is about.
    assert prompt =~ "one-shot"
  end
end
