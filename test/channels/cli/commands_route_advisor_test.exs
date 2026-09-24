defmodule OptimalSystemAgent.Channels.CLI.CommandsRouteAdvisorTest do
  @moduledoc """
  `/route` (per-step model routing) and `/advisor` (advisor consult) — the
  operator-facing on/off/configure surface for `StepRouter` and
  `Agent.Loop.Advisor`. Both default off/unconfigured (see those modules'
  moduledocs); these commands are the only way to turn them on without
  hand-editing settings.json. Same persistence pattern as `/lean-prompt`
  (`commands_lean_prompt_test.exs`): redirect `config_dir` to an isolated
  temp home so writes land in a throwaway `settings.json`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Agent.Loop.Advisor
  alias OptimalSystemAgent.Channels.CLI.Commands
  alias OptimalSystemAgent.Providers.StepRouter
  alias OptimalSystemAgent.Settings

  @sid "route-advisor-cmd-test"

  setup do
    prev_config_dir = Application.get_env(:optimal_system_agent, :config_dir)
    prev_default_provider = Application.get_env(:optimal_system_agent, :default_provider)
    prev_step_routing_enabled = Application.get_env(:optimal_system_agent, :step_routing_enabled)

    prev_step_routing_pairs =
      Application.get_env(:optimal_system_agent, :step_routing_fast_models)

    prev_advisor_enabled = Application.get_env(:optimal_system_agent, :advisor_enabled)
    prev_advisor_provider = Application.get_env(:optimal_system_agent, :advisor_provider)
    prev_advisor_model = Application.get_env(:optimal_system_agent, :advisor_model)
    prev_anthropic_key = Application.get_env(:optimal_system_agent, :anthropic_api_key)
    prev_openai_key = Application.get_env(:optimal_system_agent, :openai_api_key)
    prev_osa_home = System.get_env("OSA_HOME")

    home =
      Path.join(System.tmp_dir!(), "osa-route-advisor-cmd-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    Application.put_env(:optimal_system_agent, :config_dir, home)
    Application.put_env(:optimal_system_agent, :default_provider, :anthropic)
    Application.delete_env(:optimal_system_agent, :anthropic_api_key)
    Application.delete_env(:optimal_system_agent, :openai_api_key)
    Settings.reset_cache()

    # `/advisor status`'s auto-resolution reads REAL credentials
    # (`Auth.SubscriptionStore` under `OSA_HOME`) — isolate it from the
    # operator's own `~/.osa`, same reasoning as `advisor_test.exs`'s setup.
    osa_home_tmp =
      Path.join(
        System.tmp_dir!(),
        "osa-route-advisor-cmd-home-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(osa_home_tmp)
    System.put_env("OSA_HOME", osa_home_tmp)

    on_exit(fn ->
      File.rm_rf(home)
      File.rm_rf(osa_home_tmp)
      restore(:config_dir, prev_config_dir)
      restore(:default_provider, prev_default_provider)
      restore(:step_routing_enabled, prev_step_routing_enabled)
      restore(:step_routing_fast_models, prev_step_routing_pairs)
      restore(:advisor_enabled, prev_advisor_enabled)
      restore(:advisor_provider, prev_advisor_provider)
      restore(:advisor_model, prev_advisor_model)
      restore(:anthropic_api_key, prev_anthropic_key)
      restore(:openai_api_key, prev_openai_key)

      if prev_osa_home,
        do: System.put_env("OSA_HOME", prev_osa_home),
        else: System.delete_env("OSA_HOME")

      Settings.reset_cache()
    end)

    {:ok, home: home}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_system_agent, key)
  defp restore(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp read_settings(home),
    do: Path.join(home, "settings.json") |> File.read!() |> Jason.decode!()

  describe "registration" do
    test "/route and /advisor are registered with non-empty descriptions" do
      assert "route" in Commands.list()
      assert "advisor" in Commands.list()

      descriptions = Commands.list_with_descriptions() |> Map.new()
      assert is_binary(descriptions["route"]) and descriptions["route"] != ""
      assert is_binary(descriptions["advisor"]) and descriptions["advisor"] != ""
    end
  end

  describe "/route" do
    test "bare shows the current (default off) state without persisting anything", %{home: home} do
      output = capture_io(fn -> assert @sid = Commands.dispatch("route", @sid) end)

      assert output =~ "Per-step model routing"
      assert output =~ "off"
      refute File.exists?(Path.join(home, "settings.json"))
      refute StepRouter.enabled?(%{session_id: @sid})
    end

    test "on persists step_routing_enabled=true to settings.json", %{home: home} do
      output = capture_io(fn -> assert @sid = Commands.dispatch("route on", @sid) end)

      assert output =~ "saved to settings.json"
      assert read_settings(home)["step_routing_enabled"] == true
      assert StepRouter.enabled?(%{session_id: @sid})
    end

    test "off persists step_routing_enabled=false and reads back", %{home: home} do
      capture_io(fn -> Commands.dispatch("route on", @sid) end)
      assert StepRouter.enabled?(%{session_id: @sid})

      capture_io(fn -> Commands.dispatch("route off", @sid) end)
      refute StepRouter.enabled?(%{session_id: @sid})
      assert read_settings(home)["step_routing_enabled"] == false
    end

    test "fast <model> pairs the model with this session's current provider", %{home: home} do
      output =
        capture_io(fn -> assert @sid = Commands.dispatch("route fast haiku-fast-9", @sid) end)

      assert output =~ "anthropic"
      assert output =~ "haiku-fast-9"
      assert read_settings(home)["step_routing_fast_models"] == %{"anthropic" => "haiku-fast-9"}

      assert StepRouter.fast_model_for(:anthropic, %{session_id: @sid}) == "haiku-fast-9"
    end

    test "fast <model> merges into existing pairings instead of overwriting them", %{home: home} do
      capture_io(fn -> Commands.dispatch("route fast haiku-fast-9", @sid) end)

      Application.put_env(:optimal_system_agent, :default_provider, :openai)
      capture_io(fn -> Commands.dispatch("route fast gpt-fast-1", @sid) end)

      assert read_settings(home)["step_routing_fast_models"] == %{
               "anthropic" => "haiku-fast-9",
               "openai" => "gpt-fast-1"
             }
    end

    test "fast with no model shows usage and does not persist", %{home: home} do
      output = capture_io(fn -> assert @sid = Commands.dispatch("route fast", @sid) end)

      assert output =~ "usage"
      refute File.exists?(Path.join(home, "settings.json"))
    end
  end

  describe "/advisor" do
    test "bare shows the current (unconfigured) state without persisting anything", %{home: home} do
      output = capture_io(fn -> assert @sid = Commands.dispatch("advisor", @sid) end)

      assert output =~ "Advisor consult"
      assert output =~ "not explicitly configured"
      # No credential reachable (OSA_HOME isolated) and no live session model
      # (no real Loop for @sid) — resolve_pair/1 genuinely has nothing.
      assert output =~ "none — no credential"
      refute File.exists?(Path.join(home, "settings.json"))
    end

    test "on persists advisor_enabled=true to settings.json", %{home: home} do
      output = capture_io(fn -> assert @sid = Commands.dispatch("advisor on", @sid) end)

      assert output =~ "saved to settings.json"
      assert read_settings(home)["advisor_enabled"] == true
    end

    test "off persists advisor_enabled=false and reads back", %{home: home} do
      capture_io(fn -> Commands.dispatch("advisor on", @sid) end)
      capture_io(fn -> Commands.dispatch("advisor off", @sid) end)

      assert read_settings(home)["advisor_enabled"] == false
    end

    test "model <id> pairs the id with this session's current provider", %{home: home} do
      output =
        capture_io(fn ->
          assert @sid = Commands.dispatch("advisor model claude-opus-5-5", @sid)
        end)

      assert output =~ "anthropic:claude-opus-5-5"
      assert read_settings(home)["advisor_model"] == "claude-opus-5-5"
      assert read_settings(home)["advisor_provider"] == "anthropic"

      assert Advisor.configured_pair(%{session_id: @sid}) == {:anthropic, "claude-opus-5-5"}
    end

    test "model with no id shows usage and does not persist", %{home: home} do
      output = capture_io(fn -> assert @sid = Commands.dispatch("advisor model", @sid) end)

      assert output =~ "usage"
      refute File.exists?(Path.join(home, "settings.json"))
    end
  end
end
