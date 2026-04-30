defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Server do
  @moduledoc """
  GenServer managing a computer use session.

  Handles platform adapter dispatch, element ref resolution,
  accessibility tree caching, and idle shutdown.
  """

  use GenServer
  require Logger

  # 10 minutes
  @default_idle_timeout_ms 10 * 60 * 1_000
  # 5 seconds
  @tree_ttl_ms 5_000

  defstruct [
    :adapter,
    :platform,
    :session_id,
    :idle_timer,
    :idle_timeout_ms,
    element_refs: %{},
    last_tree: nil,
    tree_fetched_at: 0,
    step_counter: 0
  ]

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Execute an action through the server. Returns :ok | {:ok, result} | {:error, reason}."
  def execute(pid, action, params) do
    GenServer.call(pid, {:execute, action, params}, 30_000)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    platform = Keyword.fetch!(opts, :platform)
    session_id = Keyword.get(opts, :session_id, "unknown")
    idle_timeout_ms = Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms)

    timer = schedule_idle_timeout(idle_timeout_ms)

    state = %__MODULE__{
      adapter: adapter,
      platform: platform,
      session_id: session_id,
      idle_timer: timer,
      idle_timeout_ms: idle_timeout_ms
    }

    Logger.debug(
      "[CU.Server] Started for session #{session_id} (#{platform}/#{inspect(adapter)})"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, action, params}, _from, state) do
    state = reset_idle_timer(state)
    {result, state} = dispatch(action, params, state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    Logger.info("[CU.Server] Idle shutdown for session #{state.session_id}")
    {:stop, :normal, state}
  end

  # ── Dispatch ────────────────────────────────────────────────────────

  defp dispatch("screenshot", params, state) do
    case state.adapter.screenshot(params) do
      {:ok, path} ->
        case File.read(path) do
          {:ok, data} ->
            b64 = Base.encode64(data)
            {{:ok, {:image, %{media_type: "image/png", data: b64, path: path}}}, bump_step(state)}

          {:error, _} ->
            {{:ok, "Screenshot saved to #{path} but could not read file"}, bump_step(state)}
        end

      {:error, _} = err ->
        {err, state}
    end
  end

  defp dispatch("click", %{"target" => ref}, state) do
    case resolve_ref(ref, state) do
      {:ok, %{x: x, y: y, width: w, height: h}}
      when is_integer(w) and is_integer(h) and w > 0 and h > 0 ->
        cx = x + div(w, 2)
        cy = y + div(h, 2)
        result = state.adapter.click(cx, cy)
        {format_result(result, "Click on #{ref} at (#{cx}, #{cy})"), bump_step(state)}

      {:ok, %{x: x, y: y}} ->
        result = state.adapter.click(x, y)
        {format_result(result, "Click on #{ref} at (#{x}, #{y})"), bump_step(state)}

      {:error, _} = err ->
        {err, state}
    end
  end

  defp dispatch("click", %{"x" => x, "y" => y}, state) do
    result = state.adapter.click(x, y)
    {format_result(result, "Click at (#{x}, #{y})"), bump_step(state)}
  end

  defp dispatch("double_click", %{"x" => x, "y" => y}, state) do
    result = state.adapter.double_click(x, y)
    {format_result(result, "Double click at (#{x}, #{y})"), bump_step(state)}
  end

  defp dispatch("type", %{"text" => text}, state) do
    result = state.adapter.type_text(text)
    {format_result(result, "Typed #{byte_size(text)} bytes"), bump_step(state)}
  end

  defp dispatch("key", %{"text" => combo}, state) do
    result = state.adapter.key_press(combo)
    {format_result(result, "Key press: #{combo}"), bump_step(state)}
  end

  defp dispatch("scroll", params, state) do
    direction = params["direction"]
    amount = params["amount"] || 3
    result = state.adapter.scroll(direction, amount)
    {format_result(result, "Scroll #{direction}"), bump_step(state)}
  end

  defp dispatch("move_mouse", %{"x" => x, "y" => y}, state) do
    result = state.adapter.move_mouse(x, y)
    {format_result(result, "Mouse moved to (#{x}, #{y})"), bump_step(state)}
  end

  defp dispatch("drag", %{"x" => x, "y" => y, "region" => %{"x" => tx, "y" => ty}}, state) do
    result = state.adapter.drag(x, y, tx, ty)
    {format_result(result, "Dragged from (#{x},#{y}) to (#{tx},#{ty})"), bump_step(state)}
  end

  defp dispatch("drag", %{"x" => x, "y" => y, "target_x" => tx, "target_y" => ty}, state) do
    result = state.adapter.drag(x, y, tx, ty)
    {format_result(result, "Dragged from (#{x},#{y}) to (#{tx},#{ty})"), bump_step(state)}
  end

  defp dispatch("drag", %{"x" => _, "y" => _}, state) do
    {{:error, "drag requires target coordinates: either region.x/region.y or target_x/target_y"},
     state}
  end

  defp dispatch("get_tree", params, state) do
    alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Accessibility

    force = params["force_refresh"] == true
    now = System.monotonic_time(:millisecond)

    if not force and state.last_tree != nil and now - state.tree_fetched_at < @tree_ttl_ms do
      {{:ok, state.last_tree}, state}
    else
      case state.adapter.get_tree() do
        {:ok, raw_elements} ->
          parsed = Accessibility.parse_tree(raw_elements)
          {tree_text, refs} = Accessibility.assign_refs(parsed)

          state = %{state | last_tree: tree_text, tree_fetched_at: now, element_refs: refs}

          {{:ok, tree_text}, state}

        {:error, _} = err ->
          {err, state}
      end
    end
  end

  defp dispatch(action, _params, state) do
    {{:error, "Unknown action: #{action}"}, state}
  end

  defp format_result(:ok, msg), do: {:ok, msg}
  defp format_result({:error, _} = err, _msg), do: err

  # ── Element Refs ────────────────────────────────────────────────────

  defp resolve_ref(ref, state) do
    case Map.get(state.element_refs, ref) do
      nil -> {:error, "Unknown element ref: #{ref}"}
      element -> {:ok, element}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp bump_step(state), do: %{state | step_counter: state.step_counter + 1}

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    timer = schedule_idle_timeout(state.idle_timeout_ms)
    %{state | idle_timer: timer}
  end

  defp schedule_idle_timeout(ms) do
    Process.send_after(self(), :idle_timeout, ms)
  end
end
