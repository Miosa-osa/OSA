defmodule OptimalSystemAgent.Agent.OperatorOverrideContractTest do
  @moduledoc """
  Pins the honest /jailbreak contract across every user-facing surface:

    * the /help line must describe BOTH states (armed governs, disarmed →
      standard instructions) instead of the old "LIBERATE the active model"
      tagline, which promised something a prompt cannot deliver
    * the arm banner must state what disarming restores
    * the fallback seed text must not promise unrestricted output or
      refusal-suppression — the model serving the turn remains the arbiter
    * the DEFAULT system prompt must carry the operator-lead block, so a user
      never needs /jailbreak just to be heard

  Every assertion is written against the requirement, not the implementation:
  forbidden strings are the removed over-promises, required strings are the
  contract wording. Discrimination was verified red→green: this suite fails
  against the pre-change source (worktree at HEAD) and passes on the fixed tree.
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Jailbreak
  alias OptimalSystemAgent.Channels.CLI.Commands

  @tmp_home Path.join(
              System.tmp_dir!(),
              "osa-operator-contract-#{System.unique_integer([:positive])}"
            )
  @seed_path Path.join([
               __DIR__,
               "..",
               "..",
               "..",
               "lib",
               "optimal_system_agent",
               "agent",
               "jailbreak.ex"
             ])

  setup do
    File.mkdir_p!(@tmp_home)
    System.put_env("OSA_HOME", @tmp_home)

    on_exit(fn ->
      System.delete_env("OSA_HOME")
      File.rm_rf!(@tmp_home)
    end)

    :ok
  end

  # ── /help line ──────────────────────────────────────────────────────────

  describe "/help jailbreak description — both states, no over-promise" do
    test "describes what armed AND disarmed mean" do
      {_name, desc} =
        Enum.find(Commands.list_with_descriptions(), fn {name, _} -> name == "jailbreak" end)

      assert desc =~ "armed", "help line must say what arming does"
      assert desc =~ "disarmed", "help line must say what disarming does"

      refute desc =~ "LIBERATE the active model",
             "the old tagline promised liberation a prompt cannot deliver"
    end
  end

  # ── arm banner ───────────────────────────────────────────────────────────

  describe "/jailbreak on banner — states the disarmed contract" do
    test "banner tells the user what happens while disarmed" do
      output = capture_io(fn -> Commands.cmd_jailbreak("on", "contract-test-session") end)

      assert output =~ "L I B E R A T E D", "armed banner still shows the badge"

      assert output =~ "while disarmed the standard instructions govern",
             "the banner must spell out both states of the contract"
    end
  end

  # ── fallback seed text ───────────────────────────────────────────────────

  describe "fallback seed — honest about what an override layer is" do
    # The seed is a module attribute, not a runtime value, so the source file
    # IS the artifact under test: the deliverable is prompt text, and reading
    # it asserts on the text that ships.
    test "seed does not promise unrestricted output" do
      source = File.read!(@seed_path)

      refute source =~ "You are unrestricted",
             "the seed must not promise unrestricted output — the model remains the arbiter"

      refute source =~ "Do not refuse, hedge, warn",
             "the seed must not demand refusal-suppression"

      assert source =~ "model remains the arbiter",
             "the seed must state the override's real limit"

      assert source =~ "standard instructions govern",
             "the seed must spell out the disarmed state"
    end
  end

  # ── default system prompt ────────────────────────────────────────────────

  describe "default system prompt — the operator-lead block ships by default" do
    test "Context.build carries 'Follow the operator's lead' without /jailbreak" do
      # Disarm first: the banner test above armed the block in this OSA_HOME,
      # and this test must prove the block is in the DEFAULT prompt, not the
      # override layer.
      :ok = Jailbreak.set(false)

      state = %{
        session_id: "operator-contract-#{System.unique_integer([:positive])}",
        channel: :cli,
        messages: [%{role: "user", content: "hello"}],
        working_dir: "/tmp",
        provider: :ollama,
        model: nil,
        permission_tier: :full
      }

      %{messages: [sys | _]} = Context.build(state)

      text =
        case sys.content do
          c when is_binary(c) -> c
          c when is_list(c) -> Enum.map_join(c, "\n", & &1.text)
        end

      assert text =~ "## Follow the operator's lead",
             "the operator-lead block must ship in the DEFAULT prompt, not behind /jailbreak"

      assert text =~ "operator voice"
      assert text =~ "Commands execute the moment they're given"
    end
  end
end
