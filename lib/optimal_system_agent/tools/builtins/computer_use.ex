defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse do
  @moduledoc """
  Computer Use tool — interact with the desktop via screenshot, click, type, etc.

  Routes through a lazy-started GenServer for stateful operations (element refs,
  tree caching, idle shutdown) and records keyframe journal entries for trajectory
  tracking and doom loop detection.
  """

  @behaviour OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.{Adapter, Server, Keyframe}

  @valid_actions ~w(screenshot click double_click type key scroll move_mouse drag get_tree)
  @valid_scroll_directions ~w(up down left right)
  @max_text_bytes 4096
  @max_key_combo_len 120
  @key_combo_pattern ~r/^[a-zA-Z0-9+\-_ ]+$/

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def name, do: "computer_use"

  @impl true
  def description do
    "Control the computer desktop: take a screenshot, click, type text, press keys, scroll, move mouse, or drag."
  end

  @impl true
  def safety, do: :write_destructive

  @impl true
  def deferred?, do: true

  @impl true
  def available? do
    Application.get_env(:optimal_system_agent, :computer_use_enabled) === true
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "description" => "The action to perform",
          "enum" => @valid_actions
        },
        "x" => %{"type" => "integer", "description" => "X coordinate"},
        "y" => %{"type" => "integer", "description" => "Y coordinate"},
        "text" => %{"type" => "string", "description" => "Text to type or key combo"},
        "target" => %{
          "type" => "string",
          "description" => "Element ref from accessibility tree (e.g. \"e3\")"
        },
        "direction" => %{
          "type" => "string",
          "description" => "Scroll direction: up, down, left, right"
        },
        "region" => %{
          "type" => "object",
          "description" => "Screen region for screenshot or drag target",
          "properties" => %{
            "x" => %{"type" => "integer"},
            "y" => %{"type" => "integer"},
            "width" => %{"type" => "integer"},
            "height" => %{"type" => "integer"}
          }
        },
        "window" => %{
          "type" => "string",
          "description" =>
            "Window name/title to focus before executing the action (e.g. \"Editor de Texto\", \"Firefox\")"
        }
      },
      "required" => ["action"]
    }
  end

  # ---------------------------------------------------------------------------
  # Execute — validate, route through GenServer, record keyframe
  # ---------------------------------------------------------------------------

  @impl true
  def execute(%{"action" => action} = params) when action in @valid_actions do
    case validate(action, params) do
      :ok ->
        maybe_focus_window(params["window"])
        session_id = params["__session_id__"] || "default"
        server = ensure_server(session_id)
        result = Server.execute(server, action, params)
        record_keyframe(session_id, action, result)
        result

      {:error, _} = err ->
        err
    end
  end

  def execute(%{"action" => action}) when is_binary(action) do
    {:error, "Invalid action: #{action}"}
  end

  def execute(_params) do
    {:error, "Missing required parameter: action"}
  end

  # ---------------------------------------------------------------------------
  # Validation (unchanged)
  # ---------------------------------------------------------------------------

  defp validate("screenshot", params) do
    case params["region"] do
      nil -> :ok
      region -> validate_region(region)
    end
  end

  defp validate("click", params) do
    cond do
      params["target"] != nil -> :ok
      has_coords?(params) -> validate_coords(params)
      true -> {:error, "click requires either coordinates (x, y) or a target element ref"}
    end
  end

  defp validate("double_click", params), do: validate_required_coords(params)
  defp validate("move_mouse", params), do: validate_required_coords(params)
  defp validate("drag", params), do: validate_required_coords(params)
  defp validate("type", params), do: validate_text(params)
  defp validate("key", params), do: validate_key_combo(params)
  defp validate("scroll", params), do: validate_scroll(params)
  defp validate("get_tree", _params), do: :ok

  defp validate_region(%{"x" => x, "y" => y, "width" => w, "height" => h})
       when is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h) and
              x >= 0 and y >= 0 and w > 0 and h > 0 do
    :ok
  end

  defp validate_region(%{"x" => _, "y" => _, "width" => _, "height" => _}) do
    {:error, "Region must have non-negative x/y and positive width/height"}
  end

  defp validate_region(_) do
    {:error, "Region must include x, y, width, and height"}
  end

  defp has_coords?(%{"x" => x, "y" => y}) when not is_nil(x) and not is_nil(y), do: true
  defp has_coords?(_), do: false

  defp validate_coords(%{"x" => x, "y" => y}) when is_integer(x) and is_integer(y) do
    if x >= 0 and y >= 0 do
      :ok
    else
      {:error, "Coordinates must be non-negative integers"}
    end
  end

  defp validate_coords(%{"x" => x}) when not is_integer(x) do
    {:error, "Coordinate x must be an integer"}
  end

  defp validate_coords(%{"y" => y}) when not is_integer(y) do
    {:error, "Coordinate y must be an integer"}
  end

  defp validate_coords(_) do
    {:error, "Coordinates must be non-negative integers"}
  end

  defp validate_required_coords(%{"x" => x, "y" => y} = params)
       when not is_nil(x) and not is_nil(y) do
    validate_coords(params)
  end

  defp validate_required_coords(%{"x" => x}) when not is_nil(x) do
    {:error, "Missing required parameter: y"}
  end

  defp validate_required_coords(_) do
    {:error, "Missing required parameter: x"}
  end

  defp validate_text(%{"text" => text}) when is_binary(text) do
    cond do
      text == "" ->
        {:error, "Text must not be empty"}

      byte_size(text) > @max_text_bytes ->
        {:error, "Text exceeds maximum length (#{@max_text_bytes} bytes)"}

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

      byte_size(combo) >= @max_key_combo_len ->
        {:error, "Key combo too long (max #{@max_key_combo_len} characters)"}

      not Regex.match?(@key_combo_pattern, combo) ->
        {:error, "Key combo contains invalid characters"}

      true ->
        :ok
    end
  end

  defp validate_key_combo(%{"text" => _}), do: {:error, "Key combo must be a string"}
  defp validate_key_combo(_), do: {:error, "Missing required parameter: text"}

  defp validate_scroll(%{"direction" => dir}) when dir in @valid_scroll_directions, do: :ok

  defp validate_scroll(%{"direction" => dir}) when is_binary(dir),
    do: {:error, "Invalid direction: #{dir}"}

  defp validate_scroll(_), do: {:error, "Missing required parameter: direction"}

  # ---------------------------------------------------------------------------
  # Lazy GenServer management
  # ---------------------------------------------------------------------------

  @server_table :computer_use_servers

  defp ensure_server(session_id) do
    ensure_server_table()

    case :ets.lookup(@server_table, session_id) do
      [{^session_id, pid}] ->
        if Process.alive?(pid) do
          pid
        else
          :ets.delete(@server_table, session_id)
          start_server(session_id)
        end

      [] ->
        start_server(session_id)
    end
  end

  defp start_server(session_id) do
    platform = Adapter.detect_platform()

    case Adapter.adapter_for(platform) do
      {:ok, adapter} ->
        {:ok, pid} =
          Server.start_link(
            adapter: adapter,
            platform: platform,
            session_id: session_id
          )

        :ets.insert(@server_table, {session_id, pid})
        Keyframe.init_journal(session_id)
        pid

      {:error, reason} ->
        raise "Cannot start computer_use: #{reason}"
    end
  end

  defp ensure_server_table do
    try do
      :ets.new(@server_table, [:set, :public, :named_table])
    rescue
      ArgumentError -> @server_table
    end
  end

  # ---------------------------------------------------------------------------
  # Keyframe journal integration
  # ---------------------------------------------------------------------------

  defp record_keyframe(session_id, action, result) do
    result_str =
      case result do
        {:ok, {:image, %{path: p}}} -> "image:#{p}"
        {:ok, msg} when is_binary(msg) -> msg
        {:ok, other} -> inspect(other)
        {:error, reason} -> "error:#{reason}"
      end

    entry = %{action: action, result: result_str}

    # Record journal entry (best-effort, don't crash on failure)
    try do
      base = Path.expand("~/.osa/trajectories")
      journal_dir = Path.join(base, session_id)

      if File.dir?(journal_dir) do
        Keyframe.record_entry(journal_dir, entry)

        # Check for doom loop after every action
        case Keyframe.detect_doom_loop(journal_dir) do
          {:doom_loop, step_count} ->
            require Logger

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

  # ---------------------------------------------------------------------------
  # Window Focus
  # ---------------------------------------------------------------------------

  defp maybe_focus_window(nil), do: :ok
  defp maybe_focus_window(""), do: :ok

  defp maybe_focus_window(window_name) when is_binary(window_name) do
    # Window focus is only supported on Linux X11 via xdotool
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
        # Other platforms: window focus not yet supported, skip silently
        :ok
    end
  rescue
    _ -> :ok
  end
end
