defmodule OptimalSystemAgent.Agent.TrajectoryTest do
  # Mutates :config_dir / :trajectory_recording application env.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Trajectory

  setup do
    tmp = Path.join(System.tmp_dir!(), "osa_traj_t#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    prev_config_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_enabled = Application.get_env(:optimal_system_agent, :trajectory_recording)
    Application.put_env(:optimal_system_agent, :config_dir, tmp)

    on_exit(fn ->
      if prev_config_dir do
        Application.put_env(:optimal_system_agent, :config_dir, prev_config_dir)
      else
        Application.delete_env(:optimal_system_agent, :config_dir)
      end

      if prev_enabled do
        Application.put_env(:optimal_system_agent, :trajectory_recording, prev_enabled)
      else
        Application.delete_env(:optimal_system_agent, :trajectory_recording)
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "opt-in guard" do
    test "record/1 writes nothing when disabled", %{tmp: tmp} do
      Application.delete_env(:optimal_system_agent, :trajectory_recording)

      assert Trajectory.record(%{session_id: "s1", assistant_response: "hi"}) == :ok
      refute File.exists?(Path.join(tmp, "trajectories"))
    end

    test "record/1 writes when enabled" do
      Application.put_env(:optimal_system_agent, :trajectory_recording, true)

      assert Trajectory.record(%{session_id: "s2", assistant_response: "hi"}) == :ok
      assert [%{"assistant_response" => "hi"}] = Trajectory.read("s2")
    end
  end

  describe "secret redaction" do
    test "redacts provider keys, tokens, headers and KEY=value pairs" do
      text = """
      OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz012345
      export GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
      AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
      Authorization: Bearer abcdefghijklmnopqrstuvwxyz
      slack=xoxb-1234567890-abcdefghijkl
      password = hunter2000
      """

      out = Trajectory.redact(text)

      refute out =~ "sk-abcdefghijklmnopqrstuvwxyz012345"
      refute out =~ "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      refute out =~ "AKIAIOSFODNN7EXAMPLE"
      refute out =~ "abcdefghijklmnopqrstuvwxyz\n"
      refute out =~ "xoxb-1234567890-abcdefghijkl"
      refute out =~ "hunter2000"
      assert out =~ "REDACTED"
    end

    test "leaves ordinary prose alone" do
      text = "I read the file and it contains three functions."
      assert Trajectory.redact(text) == text
    end

    test "tool-call arguments and results are redacted on the way to disk" do
      Application.put_env(:optimal_system_agent, :trajectory_recording, true)

      assert Trajectory.record(%{
               session_id: "s3",
               tool_calls: [
                 %{
                   name: "shell",
                   arguments: ~s({"cmd":"export API_KEY=sk-livekey1234567890abcd"})
                 }
               ],
               tool_results: ["ANTHROPIC_API_KEY=sk-ant-verysecretvalue0123456789"],
               assistant_response: "here is your token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
             }) == :ok

      raw = File.read!(Trajectory.session_path("s3"))

      refute raw =~ "sk-livekey1234567890abcd"
      refute raw =~ "sk-ant-verysecretvalue0123456789"
      refute raw =~ "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      assert raw =~ "REDACTED"
    end
  end

  describe "retention" do
    test "maybe_prune/0 is a no-op when recording is disabled", %{tmp: tmp} do
      Application.delete_env(:optimal_system_agent, :trajectory_recording)

      dir = Path.join(tmp, "trajectories")
      File.mkdir_p!(dir)
      stale = Path.join(dir, "old.jsonl")
      File.write!(stale, "{}\n")

      assert Trajectory.maybe_prune() == 0
      assert File.exists?(stale)
    end

    test "maybe_prune/0 deletes files older than the retention window", %{tmp: tmp} do
      Application.put_env(:optimal_system_agent, :trajectory_recording, true)
      Application.put_env(:optimal_system_agent, :trajectory_retention_days, 7)
      on_exit(fn -> Application.delete_env(:optimal_system_agent, :trajectory_retention_days) end)

      dir = Path.join(tmp, "trajectories")
      File.mkdir_p!(dir)

      stale = Path.join(dir, "stale.jsonl")
      fresh = Path.join(dir, "fresh.jsonl")
      File.write!(stale, "{}\n")
      File.write!(fresh, "{}\n")

      long_ago =
        DateTime.utc_now()
        |> DateTime.add(-30, :day)
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()

      File.touch!(stale, long_ago)

      assert Trajectory.maybe_prune() == 1
      refute File.exists?(stale)
      assert File.exists?(fresh)
    end
  end
end
