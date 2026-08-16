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

    # `redact/1` now also runs over model REASONING text (the `:thinking_delta`
    # paths in `Agent.Loop.LLMClient` and `Agent.Scratchpad`), which talks about
    # token budgets constantly. `token` is a substring of `max_tokens`,
    # `token_count` and `output_tokens`, so the credential `KEY=value` pattern
    # was rewriting every one of those numbers to `[REDACTED]` and making the
    # reasoning trace unreadable.
    test "a numeric value on a credential-shaped key is left alone" do
      for text <- [
            "I should set max_tokens = 4096 for this call.",
            "The context window token_count: 12000 is nearly full.",
            "num_ctx and max_tokens: 8192 both matter here.",
            "output_tokens=2048"
          ] do
        assert Trajectory.redact(text) == text,
               "a plain number is not a credential: #{inspect(Trajectory.redact(text))}"
      end
    end

    test "the numeric exemption does not open a hole for real key shapes" do
      for text <- [
            "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz012345",
            "api_key=1234567890abcdef",
            ~s|{"api_key": "0123456789abcdef"}|,
            "SESSION_TOKEN=deadbeefcafebabe"
          ] do
        out = Trajectory.redact(text)
        assert out =~ "REDACTED", "still a secret shape, must be redacted: #{out}"
      end
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

  # ══════════════════════════════════════════════════════════════════════
  # A STORED session's cost does not move when the clock does
  #
  # This is the assertion the whole `:requested_at` feature exists for. A turn
  # is recorded through the real accounting path, written to disk through the
  # real trajectory writer, read back through the real reader, and re-costed on
  # the far side of a DeepSeek peak/off-peak boundary. The number must not move.
  #
  # Before the stamp was wired through, it moved by 2x: `Accounting` rebuilt the
  # usage map from its four token keys, `Pricing` found no instant and fell back
  # to `DateTime.utc_now/0`, and the row on disk had no way to say which tier
  # produced the `cost_usd` sitting next to it.
  # ══════════════════════════════════════════════════════════════════════
  describe "a stored turn re-prices to the same number" do
    alias OptimalSystemAgent.Agent.Loop.Accounting
    alias OptimalSystemAgent.Agent.Pricing

    test "across a peak boundary, from the row on disk" do
      Application.put_env(:optimal_system_agent, :trajectory_recording, true)

      [{model, window} | _] = Enum.to_list(Pricing.pricing_windows())
      day = DateTime.add(window.effective_from, 30, :day)
      [{peak_hour, _} | _] = window.peak_hours

      off_peak_hour =
        Enum.find(0..23, fn h ->
          not Enum.any?(window.peak_hours, fn {f, u} -> h >= f and h < u end)
        end)

      issued_at = %{day | hour: peak_hour, minute: 0, second: 0, microsecond: {0, 0}}
      viewed_at = %{day | hour: off_peak_hour, minute: 0, second: 0, microsecond: {0, 0}}

      session_id = "traj-recost-#{System.unique_integer([:positive])}"

      state = %{
        session_id: session_id,
        model: model,
        provider: :deepseek,
        messages: [],
        session_cost_usd: 0.0,
        session_input_tokens: 0,
        session_output_tokens: 0,
        session_cache_creation_tokens: 0,
        session_cache_read_tokens: 0,
        last_input_tokens: 0,
        max_budget_usd: nil
      }

      recorded =
        Accounting.record(state, %{input_tokens: 1_000_000, output_tokens: 0},
          requested_at: issued_at
        )

      # The row reached disk, carrying the instant that priced it.
      assert [row] = Trajectory.read(session_id)
      assert row["requested_at"] == DateTime.to_iso8601(issued_at)

      usage = Trajectory.usage_of(row)
      assert usage[:requested_at] == issued_at

      # Re-cost it. The explicit-instant form is what a replay/reconciliation
      # tool reaches for, and here it is handed a DIFFERENT hour on purpose —
      # the stored row's own instant must win over the one being viewed from.
      re_costed_now = Pricing.cost(model, usage)
      re_costed_from_another_hour = Pricing.cost(model, usage, usage[:requested_at])

      assert re_costed_now == re_costed_from_another_hour

      assert_in_delta re_costed_now, row["cost_usd"], 1.0e-9
      assert_in_delta re_costed_now, recorded.session_cost_usd, 1.0e-9
      assert_in_delta re_costed_now, Pricing.cost(model, usage, issued_at), 1.0e-9

      # And the measurement that makes this non-vacuous: the OTHER tier really
      # is a different number, so "did not move" is a result and not a tautology.
      unstamped = Map.delete(usage, :requested_at)
      priced_at_the_wrong_hour = Pricing.cost(model, unstamped, viewed_at)

      refute_in_delta re_costed_now,
                      priced_at_the_wrong_hour,
                      1.0e-9,
                      "the two tiers price identically — this test cannot detect drift"
    end

    test "a row written before the field existed says so instead of guessing" do
      # `timestamp` is when the response landed. Substituting it for the request
      # instant would look like a stamp and be wrong by exactly one turn's
      # duration — which is the whole distance across a boundary.
      legacy = %{
        "input_tokens" => 100,
        "output_tokens" => 10,
        "cache_creation_tokens" => 0,
        "cache_read_tokens" => 0,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      refute Map.has_key?(Trajectory.usage_of(legacy), :requested_at)
      assert Trajectory.usage_of(legacy).input_tokens == 100
    end
  end
end
