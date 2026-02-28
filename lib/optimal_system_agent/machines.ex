defmodule OptimalSystemAgent.Machines do
  @moduledoc """
  Composable skill set activation via `~/.osa/config.json`.

  Machines are groups of related skills that can be toggled on/off:
  - Core: Always active (shell_execute, file_read, file_write, web_search, web_fetch)
  - Communication: Config toggle (telegram_send, discord_send, slack_send)
  - Productivity: Config toggle (calendar_read, calendar_create, task_manager)
  - Research: Config toggle (web_search_deep, summarize, translate)

  When a machine is enabled, `activate_machines/0` registers its skills with
  the goldrush-compiled tool dispatcher and injects machine-specific prompt
  addendums into the agent's system prompt.
  """
  use GenServer
  require Logger

  defstruct active_machines: [:core], config: %{}

  defp config_dir, do: Application.get_env(:optimal_system_agent, :config_dir, "~/.osa") |> Path.expand()

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Get list of active machines."
  def active do
    GenServer.call(__MODULE__, :active)
  end

  @doc "Get prompt addendums for active machines."
  def prompt_addendums do
    GenServer.call(__MODULE__, :prompt_addendums)
  end

  @doc "Check if a specific machine is active."
  def active?(machine) do
    GenServer.call(__MODULE__, {:active?, machine})
  end

  @impl true
  def init(:ok) do
    config = load_config()
    active = determine_active_machines(config)
    Logger.info("Machines activated: #{inspect(active)}")
    {:ok, %__MODULE__{active_machines: active, config: config}}
  end

  @impl true
  def handle_call(:active, _from, state) do
    {:reply, state.active_machines, state}
  end

  def handle_call(:prompt_addendums, _from, state) do
    addendums =
      Enum.map(state.active_machines, &machine_addendum/1)
      |> Enum.reject(&is_nil/1)

    {:reply, addendums, state}
  end

  def handle_call({:active?, machine}, _from, state) do
    {:reply, machine in state.active_machines, state}
  end

  defp load_config do
    config_path = Path.join(config_dir(), "config.json")

    if File.exists?(config_path) do
      case File.read(config_path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, config} -> config
            _ -> %{}
          end
        {:error, _} -> %{}
      end
    else
      %{}
    end
  end

  defp determine_active_machines(config) do
    machines = Map.get(config, "machines", %{})

    enabled =
      machines
      |> Enum.filter(fn {_name, enabled} -> enabled == true end)
      |> Enum.map(fn {name, _} ->
        try do
          String.to_existing_atom(name)
        rescue
          ArgumentError -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    [:core | enabled] |> Enum.uniq()
  end

  defp machine_addendum(:core) do
    """
    ## Core Machine (Always Active)
    You have access to file system operations, shell execution, and web tools.
    Use these tools when the user asks you to read/write files, run commands, or search the web.
    """
  end

  defp machine_addendum(:communication) do
    """
    ## Communication Machine
    You can send messages through Telegram, Discord, and Slack.
    Ask the user which platform before sending.
    """
  end

  defp machine_addendum(:productivity) do
    """
    ## Productivity Machine
    You can manage calendars and tasks. Use these proactively when scheduling is discussed.
    """
  end

  defp machine_addendum(:research) do
    """
    ## Research Machine
    You have deep web search, summarization, and translation capabilities.
    Use these for research-heavy requests.
    """
  end

  defp machine_addendum(_), do: nil
end
