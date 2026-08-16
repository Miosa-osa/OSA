defmodule OptimalSystemAgent.Verification.VerifyLoopHandlerTest do
  @moduledoc """
  `verify_loop` must report the loop IT started.

  The handler threw away the pid `DynamicSupervisor.start_child/2` returned and
  instead ran a `Registry.select/2` over every `"vloop:"` key in the whole
  SessionRegistry, sorted `:desc`, and took the head. With any other
  verification loop registered — a concurrent session, a leftover from an
  earlier turn — it reported that loop's id, and everything keyed off the id
  then addressed the wrong process: `Loop.steer/2` injects this session's
  operator guidance into a DIFFERENT session's LLM prompt, and
  `Loop.get_state/1` returns a different session's `task_id`/`team_id`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Verification.Loop
  alias OptimalSystemAgent.Verification.Tools.VerifyLoop.Handler

  @registry OptimalSystemAgent.SessionRegistry

  # A key that sorts ABOVE anything the real loop id generator produces, so the
  # old "sort desc, take the head" strategy is guaranteed to pick it.
  @decoy_key "vloop:zzzzzzzz-not-our-loop"

  setup do
    parent = self()

    decoy =
      spawn(fn ->
        {:ok, _} = Registry.register(@registry, @decoy_key, nil)
        send(parent, :decoy_registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :decoy_registered, 1_000

    on_exit(fn -> send(decoy, :stop) end)
    :ok
  end

  test "returns the loop_id of the loop it actually started, not the newest key in the registry" do
    OptimalSystemAgent.Test.VerificationGateHelper.allow_commands(["sleep 5"])

    task_id = "task-#{System.unique_integer([:positive])}"

    {:ok, json} =
      Handler.execute(
        %{
          "test_command" => "sleep 5",
          "task_id" => task_id,
          "__session_id__" => "session-#{System.unique_integer([:positive])}"
        },
        %{}
      )

    payload = Jason.decode!(json)
    loop_id = payload["loop_id"]

    refute loop_id == String.replace_prefix(@decoy_key, "vloop:", ""),
           "handler reported an unrelated session's loop"

    refute loop_id == "unknown"

    # The reported id must address the loop we started — this is the property
    # `steer/2` and `get_state/1` depend on.
    assert {:ok, state} = Loop.get_state(loop_id)
    assert state.task_id == task_id

    [{pid, _}] = Registry.lookup(@registry, "vloop:" <> loop_id)
    Process.exit(pid, :kill)
  end
end
