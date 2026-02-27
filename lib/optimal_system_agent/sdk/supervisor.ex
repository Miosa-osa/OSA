defmodule OptimalSystemAgent.SDK.Supervisor do
  @moduledoc """
  Supervision tree for embedded SDK mode.

  Starts the minimal subset of OSA processes needed for SDK operation:
  Registry, PubSub, Bus, Repo, Providers, Skills, Memory, Budget, Hooks,
  Learning, Orchestrator, Progress, Swarm, and optionally Bandit.

  Excludes: CLI, Channels.Manager, Scheduler, Cortex, Compactor, Fleet,
  Sandbox, Wallet, Updater, OS.Registry, Machines, Commands.

  ## Usage

      config = %OptimalSystemAgent.SDK.Config{
        provider: :anthropic,
        model: "claude-sonnet-4-6"
      }

      # Add to your supervision tree:
      children = [
        {OptimalSystemAgent.SDK.Supervisor, config}
      ]
  """

  use Supervisor
  require Logger

  alias OptimalSystemAgent.SDK.Config

  def start_link(%Config{} = config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(%Config{} = config) do
    # Initialize SDK agent ETS table
    OptimalSystemAgent.SDK.Agent.init_table()

    # Load soul/personality into persistent_term
    try do
      OptimalSystemAgent.Soul.load()
      OptimalSystemAgent.PromptLoader.load()
    rescue
      _ -> :ok
    end

    children =
      [
        # Process registry
        {Registry, keys: :unique, name: OptimalSystemAgent.SessionRegistry},

        # Core infrastructure
        {Phoenix.PubSub, name: OptimalSystemAgent.PubSub},
        OptimalSystemAgent.Events.Bus,
        OptimalSystemAgent.Bridge.PubSub,
        OptimalSystemAgent.Store.Repo,

        # LLM providers
        OptimalSystemAgent.Providers.Registry,

        # Skills
        OptimalSystemAgent.Skills.Registry,

        # Channel supervisor (for session Loop processes)
        {DynamicSupervisor, name: OptimalSystemAgent.Channels.Supervisor, strategy: :one_for_one},

        # Agent processes (subset)
        OptimalSystemAgent.Agent.Memory,
        OptimalSystemAgent.Agent.Budget,
        OptimalSystemAgent.Agent.Orchestrator,
        OptimalSystemAgent.Agent.Progress,
        OptimalSystemAgent.Agent.Hooks,
        OptimalSystemAgent.Agent.Learning,

        # Intelligence (Signal Theory)
        OptimalSystemAgent.Intelligence.Supervisor,

        # Swarm
        OptimalSystemAgent.Swarm.Supervisor
      ] ++ http_children(config)

    # Register SDK tools from config
    Task.start(fn ->
      Process.sleep(100)
      register_config_tools(config)
      register_config_agents(config)
      register_config_hooks(config)
    end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Optionally start Bandit HTTP server
  defp http_children(%Config{http_port: nil}), do: []

  defp http_children(%Config{http_port: port}) when is_integer(port) do
    [{Bandit, plug: OptimalSystemAgent.Channels.HTTP, port: port}]
  end

  defp register_config_tools(%Config{tools: tools}) do
    Enum.each(tools, fn
      {name, desc, params, handler} ->
        OptimalSystemAgent.SDK.Tool.define(name, desc, params, handler)

      module when is_atom(module) ->
        OptimalSystemAgent.Skills.Registry.register(module)
    end)
  end

  defp register_config_agents(%Config{agents: agents}) do
    Enum.each(agents, fn
      %{name: name} = def -> OptimalSystemAgent.SDK.Agent.define(name, def)
      {name, def} -> OptimalSystemAgent.SDK.Agent.define(name, def)
    end)
  end

  defp register_config_hooks(%Config{hooks: hooks}) do
    Enum.each(hooks, fn
      {event, name, handler, opts} ->
        OptimalSystemAgent.SDK.Hook.register(event, name, handler, opts)

      {event, name, handler} ->
        OptimalSystemAgent.SDK.Hook.register(event, name, handler)
    end)
  end
end
