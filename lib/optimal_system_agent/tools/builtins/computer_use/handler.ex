defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `computer_use`.

  Stage split:
    * `validate/2`          — input shape checks (action enum, coord types, text length)
    * `check_permissions/2` — availability guard (computer_use_enabled config flag)
    * `execute/2`           — lazy-start GenServer routing + keyframe journaling

  All side-effecting logic is delegated to the existing Server, Adapter, and
  Keyframe modules inside `computer_use/` — this file only adds the structured
  permissioning layer on top.
  """

  require Logger

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.{Adapter, Constants, Keyframe, Server}
  alias OptimalSystemAgent.Tools.BoundedCmd
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Input validation ──────────────────────────────────────────

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx) when is_binary(action) do
    valid_strings = Constants.valid_actions() |> Enum.map(&to_string/1)

    if action in valid_strings do
      case validate_action_params(action, input) do
        :ok -> {:ok, input}
        {:error, msg} -> {:error, msg, -32_602}
      end
    else
      {:error, "Invalid action: #{action}. Valid: #{Enum.join(valid_strings, ", ")}", -32_602}
    end
  end

  def validate(%{"action" => _}, _ctx),
    do: {:error, "action must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permission check ──────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(input, _ctx) do
    if Application.get_env(:optimal_system_agent, :computer_use_enabled) === true do
      {:allow, input}
    else
      {:deny,
       "Access denied: computer_use is not enabled. Set computer_use_enabled: true in OSA config."}
    end
  end

  # ── Stage 3: Execute ───────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, any()} | {:error, String.t()}
  def execute(%{"action" => action} = params, ctx) do
    maybe_focus_window(params["window"])
    session_id = params["__session_id__"] || ctx.session_id || "default"
    result = call_server(session_id, action, params, 1)
    record_keyframe(session_id, action, result)
    result
  end

  # Fix (P1): the idle timer can stop the Server in the window between the
  # Process.alive?/1 check in ensure_server and the GenServer.call, producing an
  # :exit/:noproc crash of the whole tool call. Catch it, drop the stale ETS row,
  # and retry once against a fresh server.
  defp call_server(session_id, action, params, retries) do
    server = ensure_server(session_id)

    try do
      Server.execute(server, action, params)
    catch
      :exit, reason ->
        if retries > 0 do
          drop_stale_server(session_id)
          call_server(session_id, action, params, retries - 1)
        else
          {:error, "computer_use server unavailable: #{inspect(reason)}"}
        end
    end
  end

  defp drop_stale_server(session_id) do
    :ets.delete(Constants.server_table(), session_id)
    :ok
  rescue
    _ -> :ok
  end

  # ── Private: action-level parameter validation ─────────────────────────

  defp validate_action_params("screenshot", params) do
    case params["region"] do
      nil -> :ok
      region -> validate_region(region)
    end
  end

  defp validate_action_params("click", params) do
    cond do
      params["target"] != nil -> :ok
      has_coords?(params) -> validate_coords(params)
      true -> {:error, "click requires either coordinates (x, y) or a target element ref"}
    end
  end

  defp validate_action_params("double_click", params), do: validate_required_coords(params)
  defp validate_action_params("move_mouse", params), do: validate_required_coords(params)
  defp validate_action_params("drag", params), do: validate_required_coords(params)
  defp validate_action_params("type", params), do: validate_text(params)
  defp validate_action_params("key", params), do: validate_key_combo(params)
  defp validate_action_params("scroll", params), do: validate_scroll(params)
  defp validate_action_params("get_tree", _params), do: :ok
  defp validate_action_params("wait", params), do: validate_wait(params)
  defp validate_action_params("list_windows", _params), do: :ok
  defp validate_action_params("focus_window", params), do: validate_window_id(params)
  defp validate_action_params("launch", params), do: validate_app(params)
  defp validate_action_params("cursor", _params), do: :ok
  defp validate_action_params("snapshot", _params), do: :ok
  defp validate_action_params("right_click", params), do: validate_target_or_coords(params)
  defp validate_action_params("triple_click", params), do: validate_target_or_coords(params)
  defp validate_action_params("set_value", params), do: validate_set_value(params)
  defp validate_action_params("clipboard_get", _params), do: :ok
  defp validate_action_params("clipboard_set", params), do: validate_text(params)
  defp validate_action_params("clipboard_clear", _params), do: :ok
  defp validate_action_params("list_apps", _params), do: :ok
  defp validate_action_params("list_surfaces", _params), do: :ok
  defp validate_action_params("resize_window", params), do: validate_window_size(params)
  defp validate_action_params("move_window", params), do: validate_window_position(params)
  defp validate_action_params("scroll_to", params), do: validate_target_or_coords(params)
  defp validate_action_params("left_click", params), do: validate_action_params("click", params)
  defp validate_action_params("mouse_move", params), do: validate_required_coords(params)
  defp validate_action_params("middle_click", params), do: validate_required_coords(params)
  defp validate_action_params("left_mouse_down", params), do: validate_required_coords(params)
  defp validate_action_params("left_mouse_up", params), do: validate_required_coords(params)
  defp validate_action_params("hold_key", params), do: validate_hold_key(params)
  defp validate_action_params("left_click_drag", params), do: validate_required_coords(params)
  defp validate_action_params("cursor_position", _params), do: :ok

  defp validate_region(%{"x" => x, "y" => y, "width" => w, "height" => h})
       when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h) and
              x >= 0 and y >= 0 and w > 0 and h > 0,
       do: :ok

  defp validate_region(%{"x" => _, "y" => _, "width" => _, "height" => _}),
    do: {:error, "Region must have non-negative x/y and positive width/height"}

  defp validate_region(_),
    do: {:error, "Region must include x, y, width, and height"}

  defp has_coords?(%{"x" => x, "y" => y}) when not is_nil(x) and not is_nil(y), do: true
  defp has_coords?(_), do: false

  defp validate_coords(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y) do
    if x >= 0 and y >= 0,
      do: :ok,
      else: {:error, "Coordinates must be non-negative integers"}
  end

  defp validate_coords(%{"x" => x}) when not is_integer(x),
    do: {:error, "Coordinate x must be an integer"}

  defp validate_coords(%{"y" => y}) when not is_integer(y),
    do: {:error, "Coordinate y must be an integer"}

  defp validate_coords(_),
    do: {:error, "Coordinates must be non-negative integers"}

  defp validate_required_coords(%{"x" => x, "y" => y} = params)
       when not is_nil(x) and not is_nil(y),
       do: validate_coords(params)

  defp validate_required_coords(%{"x" => x}) when not is_nil(x),
    do: {:error, "Missing required parameter: y"}

  defp validate_required_coords(_),
    do: {:error, "Missing required parameter: x"}

  defp validate_text(%{"text" => text}) when is_binary(text) do
    cond do
      text == "" ->
        {:error, "Text must not be empty"}

      byte_size(text) > Constants.max_text_bytes() ->
        {:error, "Text exceeds maximum length (#{Constants.max_text_bytes()} bytes)"}

      true ->
        :ok
    end
  end

  defp validate_text(%{"text" => _}), do: {:error, "Text must be a string"}
  defp validate_text(_), do: {:error, "Missing required parameter: text"}

  defp validate_key_combo(%{"text" => combo}) when is_binary(combo) do
    cond do
      combo == "" ->
        {:error, "Key combo must not be empty"}

      byte_size(combo) >= Constants.max_key_combo_len() ->
        {:error, "Key combo too long (max #{Constants.max_key_combo_len()} characters)"}

      not Regex.match?(Constants.key_combo_pattern(), combo) ->
        {:error, "Key combo contains invalid characters"}

      # The character-class check above only proves the combo cannot inject
      # shell metacharacters — `ctrl+alt+del`, `super+l` and `alt+F4` all pass
      # it. Deny the combos that end the session, kill the display server,
      # force-quit, switch VT, or power the machine down: they are
      # unrecoverable from inside the agent, which loses the very screen it
      # would need to observe or undo the result.
      Constants.destructive_combo?(combo) ->
        {:error,
         "Refusing destructive key combo #{inspect(combo)} — this ends the session, " <>
           "force-quits, switches virtual terminal, or powers off the machine, and the " <>
           "agent cannot observe or undo it. Ask the user to press it themselves."}

      true ->
        :ok
    end
  end

  defp validate_key_combo(%{"text" => _}), do: {:error, "Key combo must be a string"}
  defp validate_key_combo(_), do: {:error, "Missing required parameter: text"}

  defp validate_scroll(%{"direction" => dir} = params)
       when dir in ["up", "down", "left", "right"] do
    case Map.get(params, "amount") do
      nil -> :ok
      a when is_integer(a) and a > 0 and a <= 100 -> :ok
      _ -> {:error, "amount must be an integer between 1 and 100"}
    end
  end

  defp validate_scroll(%{"direction" => dir}) when is_binary(dir),
    do: {:error, "Invalid direction: #{dir}"}

  defp validate_scroll(_),
    do: {:error, "Missing required parameter: direction"}

  defp validate_wait(params) do
    seconds = Map.get(params, "seconds", 1)

    if is_number(seconds) and seconds >= 0 and seconds <= 30 do
      :ok
    else
      {:error, "seconds must be a number between 0 and 30"}
    end
  end

  defp validate_hold_key(params) do
    with :ok <- validate_key_combo(params) do
      case Map.get(params, "duration") do
        nil -> :ok
        d when is_number(d) and d >= 0 and d <= 30 -> :ok
        _ -> {:error, "duration must be a number between 0 and 30"}
      end
    end
  end

  defp validate_window_id(%{"window_id" => id}) when is_binary(id) and id != "", do: :ok
  defp validate_window_id(_), do: {:error, "Missing required parameter: window_id"}

  defp validate_app(%{"app" => app}) when is_binary(app) and app != "", do: :ok
  defp validate_app(_), do: {:error, "Missing required parameter: app"}

  defp validate_target_or_coords(params) do
    cond do
      params["target"] != nil -> :ok
      has_coords?(params) -> validate_coords(params)
      true -> {:error, "action requires either coordinates (x, y) or a target element ref"}
    end
  end

  defp validate_set_value(params) do
    with :ok <- validate_text(params),
         :ok <- validate_target_or_coords(params) do
      :ok
    end
  end

  defp validate_window_size(%{"window_id" => id, "width" => width, "height" => height})
       when is_binary(id) and id != "" and is_integer(width) and is_integer(height) and width > 0 and
              height > 0,
       do: :ok

  defp validate_window_size(%{"window_id" => id}) when is_binary(id) and id != "",
    do: {:error, "resize_window requires positive integer width and height"}

  defp validate_window_size(_), do: {:error, "Missing required parameter: window_id"}

  defp validate_window_position(%{"window_id" => id, "x" => x, "y" => y})
       when is_binary(id) and id != "" and is_integer(x) and is_integer(y),
       do: :ok

  defp validate_window_position(%{"window_id" => id}) when is_binary(id) and id != "",
    do: {:error, "move_window requires integer x and y"}

  defp validate_window_position(_), do: {:error, "Missing required parameter: window_id"}

  # ── Private: lazy GenServer management ────────────────────────────────

  defp ensure_server(session_id) do
    table = Constants.server_table()
    ensure_server_table(table)

    case :ets.lookup(table, session_id) do
      [{^session_id, pid}] ->
        if Process.alive?(pid) do
          pid
        else
          :ets.delete(table, session_id)
          start_server(session_id, table)
        end

      [] ->
        start_server(session_id, table)
    end
  end

  defp start_server(session_id, table) do
    platform = Adapter.detect_platform()

    case Adapter.adapter_for(platform) do
      {:ok, adapter} ->
        {:ok, pid} =
          Server.start_link(
            adapter: adapter,
            platform: platform,
            session_id: session_id
          )

        :ets.insert(table, {session_id, pid})
        Keyframe.init_journal(session_id)
        maybe_housekeeping()
        pid

      {:error, reason} ->
        raise "Cannot start computer_use: #{reason}"
    end
  end

  defp ensure_server_table(table) do
    try do
      :ets.new(table, [:set, :public, :named_table])
    rescue
      ArgumentError -> table
    end
  end

  # ── Private: disk hygiene ──────────────────────────────────────────────

  defp maybe_housekeeping do
    try do
      base = Path.expand("~/.osa/trajectories")
      if File.dir?(base), do: Keyframe.cleanup_old_journals(base)
      prune_old_files(Path.expand("~/.osa/screenshots"), 86_400)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp prune_old_files(dir, max_age_seconds) do
    now = System.system_time(:second)

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(dir, entry)

          with true <- File.regular?(path),
               {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
               true <- now - mtime > max_age_seconds do
            File.rm(path)
          else
            _ -> :ok
          end
        end)

      _ ->
        :ok
    end
  end

  # ── Private: keyframe journal ──────────────────────────────────────────

  defp record_keyframe(session_id, action, result) do
    result_str =
      case result do
        {:ok, {:image, %{path: p}}} -> "image:#{p}"
        {:ok, msg} when is_binary(msg) -> msg
        {:ok, other} -> inspect(other)
        {:error, reason} -> "error:#{reason}"
      end

    entry = %{action: action, result: result_str}

    try do
      base = Path.expand("~/.osa/trajectories")
      journal_dir = Path.join(base, session_id)

      if File.dir?(journal_dir) do
        Keyframe.record_entry(journal_dir, entry)

        case Keyframe.detect_doom_loop(journal_dir) do
          {:doom_loop, step_count} ->
            Logger.warning(
              "[CU] Doom loop detected at step #{step_count} for session #{session_id}"
            )

          :ok ->
            :ok
        end
      end
    rescue
      _ -> :ok
    end
  end

  # ── Private: window focus ──────────────────────────────────────────────

  defp maybe_focus_window(nil), do: :ok
  defp maybe_focus_window(""), do: :ok

  defp maybe_focus_window(window_name) when is_binary(window_name) do
    case Adapter.detect_platform() do
      :linux_x11 ->
        case BoundedCmd.run("xdotool", ["search", "--name", window_name],
               label: "xdotool search",
               target: window_name
             ) do
          {:ok, output, 0} ->
            case output |> String.split("\n", trim: true) |> List.first() do
              nil ->
                :ok

              wid ->
                # `--sync` blocks until the window manager confirms the
                # activation. A WM that never confirms — a modal grab, a
                # crashed compositor — held this call, and therefore the whole
                # turn, forever. This is a best-effort focus, so an expiry is
                # simply not-focused rather than an error surfaced upward.
                _ =
                  BoundedCmd.run("xdotool", ["windowactivate", "--sync", String.trim(wid)],
                    label: "xdotool windowactivate --sync",
                    target: window_name
                  )

                Process.sleep(200)
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
