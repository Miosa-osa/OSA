defmodule OptimalSystemAgent.Skin.Engine do
  @moduledoc "Skin engine — loads, caches, and serves theme skins."
  use GenServer
  require Logger

  alias OptimalSystemAgent.Skin.{Loader, Schema}

  @persistent_key {__MODULE__, :active_skin}
  @skins_key {__MODULE__, :all_skins}

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec active_skin() :: Schema.t()
  def active_skin do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> default_skin()
      skin -> skin
    end
  end

  @spec list_skins() :: [map()]
  def list_skins do
    active = active_skin()
    all = :persistent_term.get(@skins_key, %{})

    Enum.map(all, fn {name, skin} ->
      %{
        name: name,
        display_name: skin.display_name,
        description: skin.description,
        active: name == active.name
      }
    end)
  end

  @spec set_active(String.t()) :: :ok | {:error, String.t()}
  def set_active(name) do
    GenServer.call(__MODULE__, {:set_active, name})
  end

  @spec reload() :: :ok
  def reload do
    GenServer.cast(__MODULE__, :reload)
  end

  # ── Server callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    skins = Loader.load_all()
    active_name = OptimalSystemAgent.Settings.get("skin", "dark")

    active = Map.get(skins, active_name) || Map.get(skins, "dark") || default_skin()

    :persistent_term.put(@skins_key, skins)
    :persistent_term.put(@persistent_key, active)

    Logger.info(
      "[skin] Engine started — #{map_size(skins)} skin(s) loaded, active: #{active.name}"
    )

    {:ok, %{}}
  end

  @impl true
  def handle_call({:set_active, name}, _from, state) do
    all = :persistent_term.get(@skins_key, %{})

    case Map.get(all, name) do
      nil ->
        available = Map.keys(all) |> Enum.join(", ")

        {:reply,
         {:error, "Skin '#{name}' not found. Available: #{available}"},
         state}

      skin ->
        :persistent_term.put(@persistent_key, skin)
        OptimalSystemAgent.Settings.set_user("skin", name)
        Logger.info("[skin] Active skin changed to: #{name}")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast(:reload, state) do
    skins = Loader.load_all()
    :persistent_term.put(@skins_key, skins)
    # Re-resolve active skin in case it was updated on disk
    active_name = OptimalSystemAgent.Settings.get("skin", "dark")
    active = Map.get(skins, active_name) || Map.get(skins, "dark") || default_skin()
    :persistent_term.put(@persistent_key, active)
    Logger.info("[skin] Reloaded — #{map_size(skins)} skin(s)")
    {:noreply, state}
  end

  defp default_skin do
    {:ok, skin} =
      Schema.from_map(%{
        "name" => "dark",
        "display_name" => "Dark",
        "description" => "Default dark theme"
      })

    skin
  end
end
