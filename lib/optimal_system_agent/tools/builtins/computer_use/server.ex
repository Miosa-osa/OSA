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
    click_resolved_ref(ref, state)
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

  defp dispatch("wait", params, state) do
    if function_exported?(state.adapter, :wait, 1) do
      result = state.adapter.wait(Map.get(params, "seconds", 1))
      {format_result(result, "Waited"), bump_step(state)}
    else
      {{:error, "wait is not supported by #{inspect(state.adapter)}"}, state}
    end
  end

  defp dispatch("list_windows", _params, state) do
    if function_exported?(state.adapter, :list_windows, 0) do
      {state.adapter.list_windows(), bump_step(state)}
    else
      {{:error, "list_windows is not supported by #{inspect(state.adapter)}"}, state}
    end
  end

  defp dispatch("focus_window", %{"window_id" => window_id}, state) do
    if function_exported?(state.adapter, :focus_window, 1) do
      result = state.adapter.focus_window(window_id)
      {format_result(result, "Focused window #{window_id}"), bump_step(state)}
    else
      {{:error, "focus_window is not supported by #{inspect(state.adapter)}"}, state}
    end
  end

  defp dispatch("launch", %{"app" => app}, state) do
    if function_exported?(state.adapter, :launch, 1) do
      result = state.adapter.launch(app)
      {format_result(result, "Launched #{app}"), bump_step(state)}
    else
      {{:error, "launch is not supported by #{inspect(state.adapter)}"}, state}
    end
  end

  defp dispatch("cursor", _params, state) do
    if function_exported?(state.adapter, :cursor, 0) do
      {state.adapter.cursor(), bump_step(state)}
    else
      {{:error, "cursor is not supported by #{inspect(state.adapter)}"}, state}
    end
  end

  defp dispatch("snapshot", params, state) do
    adapter_result(state, :snapshot, [params])
  end

  defp dispatch("right_click", params, state) do
    adapter_ok(state, :right_click, [params], "Right click")
  end

  defp dispatch("triple_click", params, state) do
    adapter_ok(state, :triple_click, [params], "Triple click")
  end

  defp dispatch("set_value", params, state) do
    adapter_ok(state, :set_value, [params], "Set value")
  end

  defp dispatch("clipboard_get", _params, state) do
    adapter_result(state, :clipboard_get, [])
  end

  defp dispatch("clipboard_set", %{"text" => text}, state) do
    adapter_ok(state, :clipboard_set, [text], "Clipboard set")
  end

  defp dispatch("clipboard_clear", _params, state) do
    adapter_ok(state, :clipboard_clear, [], "Clipboard cleared")
  end

  defp dispatch("list_apps", _params, state) do
    adapter_result(state, :list_apps, [])
  end

  defp dispatch("list_surfaces", params, state) do
    adapter_result(state, :list_surfaces, [params])
  end

  defp dispatch("resize_window", params, state) do
    adapter_ok(state, :resize_window, [params], "Window resized")
  end

  defp dispatch("move_window", params, state) do
    adapter_ok(state, :move_window, [params], "Window moved")
  end

  defp dispatch("scroll_to", params, state) do
    adapter_ok(state, :scroll_to, [params], "Scrolled to target")
  end

  defp dispatch(action, _params, state) do
    {{:error, "Unknown action: #{action}"}, state}
  end

  defp format_result(:ok, msg), do: {:ok, msg}
  defp format_result({:error, _} = err, _msg), do: err

  defp adapter_result(state, function, args) do
    if function_exported?(state.adapter, function, length(args)) do
      {apply(state.adapter, function, args), bump_step(state)}
    else
      {{:error, "#{function} is not supported by #{inspect(state.adapter)}"}, state}
    end
  end

  defp adapter_ok(state, function, args, message) do
    if function_exported?(state.adapter, function, length(args)) do
      result = apply(state.adapter, function, args)
      {format_result(result, message), bump_step(state)}
    else
      {{:error, "#{function} is not supported by #{inspect(state.adapter)}"}, state}
    end
  end

  # ── Element Refs ────────────────────────────────────────────────────

  defp resolve_ref(ref, state) do
    case Map.get(state.element_refs, ref) do
      nil -> {:error, "Unknown element ref: #{ref}"}
      element -> {:ok, element}
    end
  end

  defp click_resolved_ref(ref, state) do
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
