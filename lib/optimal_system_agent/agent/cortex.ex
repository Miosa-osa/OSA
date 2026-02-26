defmodule OptimalSystemAgent.Agent.Cortex do
  @moduledoc """
  Memory synthesis engine.

  Periodically synthesizes a "memory bulletin" from:
  - Recent conversations across all channels
  - Updated memory graph nodes
  - Pattern detection across contacts

  The bulletin is injected into the system prompt so the agent
  has ambient awareness of what's happening across all channels.

  The synthesis runs on a configurable interval (default 5 minutes).
  `bulletin/0` is a fast read of cached state — safe to call on every
  context build. `refresh/0` forces an immediate re-synthesis.
  """
  use GenServer
  require Logger

  @default_refresh_interval 300_000
  @boot_delay 30_000

  defstruct [
    bulletin: nil,
    last_refresh: nil,
    refresh_interval: @default_refresh_interval,
    timer_ref: nil
  ]

  # --- Public API ---

  @doc """
  Returns the current memory bulletin string, or nil if none is available.
  Fast call — reads cached GenServer state only.
  """
  @spec bulletin() :: String.t() | nil
  def bulletin do
    GenServer.call(__MODULE__, :bulletin)
  end

  @doc """
  Force an immediate bulletin refresh. Returns :ok immediately;
  the synthesis happens asynchronously.
  """
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # --- GenServer lifecycle ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    interval = Application.get_env(:optimal_system_agent, :cortex_refresh_interval, @default_refresh_interval)
    timer_ref = Process.send_after(self(), :refresh, @boot_delay)

    state = %__MODULE__{
      refresh_interval: interval,
      timer_ref: timer_ref
    }

    Logger.info("Cortex started — first synthesis in #{@boot_delay}ms, interval #{interval}ms")
    {:ok, state}
  end

  # --- Callbacks ---

  @impl true
  def handle_call(:bulletin, _from, state) do
    {:reply, state.bulletin, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    state = cancel_timer(state)
    new_state = do_synthesis(state)
    timer_ref = Process.send_after(self(), :refresh, new_state.refresh_interval)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = cancel_timer(state)
    new_state = do_synthesis(state)
    timer_ref = Process.send_after(self(), :refresh, new_state.refresh_interval)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  # --- Synthesis ---

  defp do_synthesis(state) do
    memory_content = OptimalSystemAgent.Agent.Memory.recall()

    if memory_content == "" do
      Logger.debug("Cortex: no memory content, skipping synthesis")
      %{state | last_refresh: DateTime.utc_now()}
    else
      messages = build_synthesis_messages(memory_content)

      case OptimalSystemAgent.Providers.Registry.chat(messages, max_tokens: 300, temperature: 0.3) do
        {:ok, %{content: content}} when is_binary(content) and content != "" ->
          bulletin = String.trim(content)
          Logger.info("Cortex: bulletin refreshed (#{byte_size(bulletin)} bytes)")
          %{state | bulletin: bulletin, last_refresh: DateTime.utc_now()}

        {:ok, %{content: _}} ->
          Logger.warning("Cortex: LLM returned empty content, keeping previous bulletin")
          %{state | last_refresh: DateTime.utc_now()}

        {:error, reason} ->
          Logger.warning("Cortex: synthesis failed — #{inspect(reason)}, keeping previous bulletin")
          %{state | last_refresh: DateTime.utc_now()}
      end
    end
  end

  defp build_synthesis_messages(memory_content) do
    prompt = """
    You are a memory synthesis engine. Summarize the following recent activity into a brief bulletin (max 200 words) for an AI assistant. Focus on:
    1. What the user is currently working on
    2. Any pending tasks or open questions
    3. Key decisions or preferences expressed
    4. Patterns worth noting

    Recent activity:
    #{memory_content}

    Bulletin:
    """

    [%{role: "user", content: prompt}]
  end

  # --- Helpers ---

  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
