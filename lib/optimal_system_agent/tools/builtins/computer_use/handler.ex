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
    server = ensure_server(session_id)
    result = Server.execute(server, action, params)
    record_keyframe(session_id, action, result)
    result
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

      true ->
        :ok
    end
  end

  defp validate_key_combo(%{"text" => _}), do: {:error, "Key combo must be a string"}
  defp validate_key_combo(_), do: {:error, "Missing required parameter: text"}

  defp validate_scroll(%{"direction" => dir})
       when dir in ["up", "down", "left", "right"],
       do: :ok

  defp validate_scroll(%{"direction" => dir}) when is_binary(dir),
    do: {:error, "Invalid direction: #{dir}"}

  defp validate_scroll(_),
    do: {:error, "Missing required parameter: direction"}

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
        case System.cmd("xdotool", ["search", "--name", window_name], stderr_to_stdout: true) do
          {output, 0} ->
            case output |> String.split("\n", trim: true) |> List.first() do
              nil ->
                :ok

              wid ->
                System.cmd("xdotool", ["windowactivate", "--sync", String.trim(wid)],
                  stderr_to_stdout: true
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
