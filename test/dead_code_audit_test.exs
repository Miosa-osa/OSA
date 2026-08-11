defmodule OptimalSystemAgent.DeadCodeAuditTest do
  @moduledoc """
  Regression tests for defects found by the dead-code audit.

  Each test pins a wiring that was silently broken: a supervised process nobody
  registered against, a registered tool calling a module that does not exist, an
  adapter that no dispatch clause could reach, and three HTTP routes calling a
  module that has never existed in this repo.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  describe "process registry naming" do
    test "OptimalSystemAgent.Registry is started under the name Teams and Workspace use" do
      # `teams/manager.ex`, `teams/nervous_system.ex`, `teams/cost_tracker.ex` and
      # `workspace/workspace.ex` all register `{:via, Registry, {OptimalSystemAgent.Registry, _}}`.
      # The supervisor previously started `OptimalSystemAgent.Teams.Registry`
      # instead, so the first `team_create` raised `unknown registry`.
      assert Registry.lookup(OptimalSystemAgent.Registry, {__MODULE__, "no-such-team"}) == []
    end

    test "the unused Teams.Registry name is gone" do
      assert Process.whereis(OptimalSystemAgent.Teams.Registry) == nil
    end
  end

  describe "computer_use adapters are reachable" do
    test "every shipped adapter has an adapter_for/1 clause" do
      for {platform, mod} <- [
            macos: OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.MacOS,
            linux_x11: OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxX11,
            linux_wayland: OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.LinuxWayland,
            windows: OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.Windows,
            miosa: OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.Miosa,
            docker: OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.Docker,
            remote_ssh: OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.RemoteSSH,
            platform_vm: OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.PlatformVM
          ] do
        assert Adapter.adapter_for(platform) == {:ok, mod},
               "#{platform} adapter module ships but adapter_for/1 cannot reach it"
      end
    end

    test "the documented :computer_use_platform override reaches a remote adapter" do
      prev = Application.get_env(:optimal_system_agent, :computer_use_platform)
      on_exit(fn -> Application.put_env(:optimal_system_agent, :computer_use_platform, prev) end)

      Application.put_env(:optimal_system_agent, :computer_use_platform, :docker)
      assert Adapter.detect_platform() == :docker
      assert {:ok, _} = Adapter.adapter_for(Adapter.detect_platform())
    end
  end

  describe "no module is called that does not exist" do
    test "semantic_search only calls modules that are loadable" do
      # The tool is registered (tools/registry.ex) and therefore user-reachable.
      # It used to alias `Agent.Memory` and `Agent.Learning`, neither of which
      # exists, so both branches raised and were swallowed into error text.
      assert Code.ensure_loaded?(OptimalSystemAgent.SDK.Memory)
      assert Code.ensure_loaded?(OptimalSystemAgent.Memory.Learning)
      assert function_exported?(OptimalSystemAgent.SDK.Memory, :recall_relevant, 2)
      assert function_exported?(OptimalSystemAgent.Memory.Learning, :patterns, 0)
      assert function_exported?(OptimalSystemAgent.Memory.Learning, :solutions, 0)

      refute Code.ensure_loaded?(OptimalSystemAgent.Agent.Memory)
      refute Code.ensure_loaded?(OptimalSystemAgent.Agent.Learning)
    end

    test "CommandCenterRoutes does not reference the nonexistent Webhooks.Dispatcher" do
      refute Code.ensure_loaded?(OptimalSystemAgent.Webhooks.Dispatcher)

      source = File.read!("lib/optimal_system_agent/channels/http/api/command_center_routes.ex")

      refute source =~ ~r/^\s*(webhooks = |case )?Dispatcher\./m,
             "command_center_routes.ex calls Webhooks.Dispatcher, which does not exist"
    end
  end

  describe "deleted dead code stays deleted" do
    test "Tools.Cache is gone" do
      refute Code.ensure_loaded?(OptimalSystemAgent.Tools.Cache)
      assert :ets.info(:tool_result_cache) == :undefined
    end

    test "the goldrush tool dispatcher is not compiled" do
      # `:glc.compile(:osa_tool_dispatcher, _)` cost ~6s at 82 tools and had zero
      # readers. `:osa_event_router` (Events.Bus) is the only live goldrush module.
      refute Code.ensure_loaded?(:osa_tool_dispatcher)
      refute function_exported?(OptimalSystemAgent.Tools.Registry, :ensure_dispatcher, 0)
    end

    test "Agent.Progress is gone" do
      # 535 lines whose only input was a Bus handler filtering on
      # `:orchestrator_*` atoms that nothing emits, and whose entire public API
      # (format/1, get/1, list/0, subscribe/2) had zero callers. Not to be
      # confused with Agent.ProgressLedger, which is live.
      refute Code.ensure_loaded?(OptimalSystemAgent.Agent.Progress)
      assert Code.ensure_loaded?(OptimalSystemAgent.Agent.ProgressLedger)
    end

    test "nothing matches :orchestrator_* atoms on the Bus" do
      # Orchestrator publishes those names as STRINGS on PubSub. Any Bus clause
      # matching them as atoms is unreachable by construction.
      producers =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn f ->
          File.read!(f)
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> line =~ ~r/event: :orchestrator_/ end)
          |> Enum.map(fn {line, n} -> "#{f}:#{n}: #{String.trim(line)}" end)
        end)

      assert producers == [],
             "found `event: :orchestrator_*` (atom) usages; the Bus only ever carries " <>
               "these as strings on PubSub:\n" <> Enum.join(producers, "\n")
    end

    test "the CLI's proactive-message handler is gone" do
      # `:proactive_message` had ZERO producers in the entire tree, so this
      # handler registered a Bus callback on every CLI session that could never
      # fire. Deleted along with its call site in channels/cli.ex.
      refute function_exported?(
               OptimalSystemAgent.Channels.CLI.Events,
               :register_proactive_handler,
               1
             )

      assert Path.wildcard("lib/**/*.ex")
             |> Enum.filter(&(File.read!(&1) =~ "proactive_message")) == []
    end

    test "background_agent_started is emitted on the Bus like its siblings" do
      # started/completed/failed are rendered by the same CLI handler, but only
      # completed and failed were dual-emitted on the Bus — started went to
      # PubSub alone, so the CLI never printed the launch line.
      src = File.read!("lib/optimal_system_agent/orchestrator.ex")

      for evt <- ~w(background_agent_started background_agent_completed background_agent_failed) do
        assert src =~ "event: :#{evt}",
               "#{evt} is not emitted as an atom on Events.Bus; " <>
                 "channels/cli/events.ex matches it as one"
      end
    end

    test "the dead OS template-discovery subsystem is gone" do
      refute Code.ensure_loaded?(OptimalSystemAgent.OS.Registry)
      refute Code.ensure_loaded?(OptimalSystemAgent.OS.Scanner)
      refute Code.ensure_loaded?(OptimalSystemAgent.OS.Manifest)
      # OS.Shell is the live sibling and must survive.
      assert Code.ensure_loaded?(OptimalSystemAgent.OS.Shell)
    end
  end
end
