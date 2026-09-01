defmodule OptimalSystemAgent.Agent.VoiceTest do
  @moduledoc """
  State semantics for the /voice switch (Agent.Voice).

  The orb PROCESS is not spawned here — these tests pin the contract that
  can lie: the state file, active?/0's honesty, and error paths. The
  spawn/kill lifecycle is verified end-to-end against the real orb app
  (see the session log: boot probe, voice.json flip → self-quit).
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Voice

  @tmp_home Path.join(System.tmp_dir!(), "osa-voice-test-#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@tmp_home)
    System.put_env("OSA_HOME", @tmp_home)
    # Point at a nonexistent app dir so enable/1 exercises its error path
    # WITHOUT ever spawning a real Electron process from the test suite.
    System.put_env("OSA_VOICE_APP", Path.join(@tmp_home, "no-such-app"))

    on_exit(fn ->
      System.delete_env("OSA_HOME")
      System.delete_env("OSA_VOICE_APP")
      File.rm_rf!(@tmp_home)
    end)

    :ok
  end

  test "inactive by default: no state file, honest status" do
    refute Voice.active?()
    assert Voice.status_line() == "voice off"
    assert is_nil(Voice.session_id())
  end

  test "enable with a missing app dir errors and never claims active" do
    assert {:error, {:app_missing, _app}} = Voice.enable("sess-1")
    refute Voice.active?()
    assert Voice.status_line() == "voice off"
  end

  test "disable persists enabled=false even from a cold start" do
    :ok = Voice.disable()

    meta = Jason.decode!(File.read!(Path.join(@tmp_home, "voice.json")))
    assert meta["enabled"] == false
    refute Voice.active?()
  end

  test "a stale enabled=true flag with no live orb does not lie" do
    # Crash-safety contract: the flag alone never claims voice mode —
    # active?/0 also requires the orb's vite port to answer.
    File.write!(Path.join(@tmp_home, "voice.json"), Jason.encode!(%{"enabled" => true}))
    # Nothing listens on the orb port in this test env → must read false.
    refute Voice.active?()
    assert Voice.status_line() == "voice off"
  end
end
