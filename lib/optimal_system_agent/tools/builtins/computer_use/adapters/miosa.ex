defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapters.Miosa do
  @moduledoc """
  Computer-use adapter for MIOSA cloud computers and OpenComputers hosts.

  It forwards desktop primitives to the public MIOSA REST API documented at
  `https://miosa.ai/docs/api-reference/desktop/`. Configure it with:

      config :optimal_system_agent, :computer_use_platform, :miosa
      config :optimal_system_agent, :computer_use_miosa,
        computer_id: "uuid",
        api_key: System.get_env("MIOSA_API_KEY"),
        base_url: "https://api.miosa.ai/api/v1"

  OpenComputers machines registered with MIOSA expose the same `/desktop/*`
  surface as MIOSA-managed cloud computers, so no adapter change is needed when
  switching between them.
  """

  @behaviour OptimalSystemAgent.Tools.Builtins.ComputerUse.Adapter

  @default_base_url "https://api.miosa.ai/api/v1"

  @impl true
  def available? do
    config = get_config()
    present?(config[:computer_id]) and present?(api_key(config))
  end

  @impl true
  def screenshot(opts) do
    path =
      case Map.get(opts, "region") do
        %{"x" => _, "y" => _, "width" => _, "height" => _} ->
          request(:post, "/desktop/screenshot/region", Map.get(opts, "region"))

        _ ->
          request(:get, "/desktop/screenshot")
      end

    with {:ok, png} <- path,
         {:ok, local_path} <- save_screenshot(png) do
      {:ok, local_path}
    end
  end

  @impl true
  def click(x, y), do: ok_request(:post, "/desktop/click", %{x: x, y: y})

  @impl true
  def double_click(x, y), do: ok_request(:post, "/desktop/double-click", %{x: x, y: y})

  @impl true
  def type_text(text), do: ok_request(:post, "/desktop/type", %{text: text})

  @impl true
  def key_press(combo), do: ok_request(:post, "/desktop/key", %{key: combo})

  @impl true
  def scroll(direction, amount) do
    ok_request(:post, "/desktop/scroll", %{x: 0, y: 0, direction: direction, amount: amount})
  end

  @impl true
  def move_mouse(_x, _y) do
    {:error, "MIOSA Desktop API does not expose move_mouse; use click, drag, scroll, or cursor"}
  end

  @impl true
  def drag(start_x, start_y, end_x, end_y) do
    ok_request(:post, "/desktop/drag", %{
      start_x: start_x,
      start_y: start_y,
      end_x: end_x,
      end_y: end_y
    })
  end

  @impl true
  def get_tree do
    {:error, "MIOSA Desktop API does not expose an accessibility tree; use screenshot"}
  end

  def wait(seconds), do: ok_request(:post, "/desktop/wait", %{seconds: seconds})
  def list_windows, do: request(:get, "/desktop/windows")

  def focus_window(window_id),
    do: ok_request(:post, "/desktop/window/focus", %{window_id: window_id})

  def launch(app), do: ok_request(:post, "/desktop/launch", %{app: app})
  def cursor, do: request(:get, "/desktop/cursor")
  def snapshot(params), do: request(:post, "/desktop/snapshot", compact_body(params))
  def right_click(params), do: ok_request(:post, "/desktop/right-click", compact_body(params))
  def triple_click(params), do: ok_request(:post, "/desktop/triple-click", compact_body(params))
  def set_value(params), do: ok_request(:post, "/desktop/set-value", compact_body(params))
  def clipboard_get, do: request(:get, "/desktop/clipboard")
  def clipboard_set(text), do: ok_request(:post, "/desktop/clipboard", %{text: text})
  def clipboard_clear, do: ok_request(:delete, "/desktop/clipboard", nil)
  def list_apps, do: request(:get, "/desktop/apps")
  def list_surfaces(params), do: request(:post, "/desktop/surfaces", compact_body(params))
  def resize_window(params), do: ok_request(:post, "/desktop/window/resize", compact_body(params))
  def move_window(params), do: ok_request(:post, "/desktop/window/move", compact_body(params))
  def scroll_to(params), do: ok_request(:post, "/desktop/scroll-to", compact_body(params))

  defp ok_request(method, path, body) do
    case request(method, path, body) do
      {:ok, _body} -> :ok
      {:error, _} = err -> err
    end
  end

  defp request(method, path, body \\ nil) do
    config = get_config()

    with {:ok, computer_id} <- fetch_config(config, :computer_id),
         {:ok, key} <- fetch_api_key(config) do
      url = base_url(config) <> "/computers/#{computer_id}" <> path
      headers = [{"authorization", "Bearer #{key}"}]
      opts = [method: method, url: url, headers: headers, receive_timeout: 30_000, retry: false]
      opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

      case do_request(config, opts, body) do
        {:ok, status, response_body} when status in 200..299 ->
          {:ok, response_body}

        {:ok, status, response_body} ->
          {:error, "MIOSA desktop API returned HTTP #{status}: #{format_body(response_body)}"}

        {:error, reason} ->
          {:error, "MIOSA desktop API request failed: #{inspect(reason)}"}
      end
    end
  end

  defp save_screenshot(png) when is_binary(png) do
    dir = Path.expand("~/.osa/screenshots")
    File.mkdir_p!(dir)
    path = Path.join(dir, "miosa_#{System.system_time(:millisecond)}.png")
    File.write!(path, png, [:binary])
    {:ok, path}
  rescue
    e -> {:error, "Could not save MIOSA screenshot: #{Exception.message(e)}"}
  end

  defp save_screenshot(_), do: {:error, "MIOSA screenshot response was not binary PNG data"}

  defp do_request(config, opts, body) do
    case config[:request] do
      fun when is_function(fun, 4) ->
        fun.(opts[:method], opts[:url], opts[:headers], body)
        |> normalize_response()

      _ ->
        Req.request(opts) |> normalize_response()
    end
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:ok, status, body}

  defp normalize_response({:ok, status, body}) when is_integer(status), do: {:ok, status, body}
  defp normalize_response({:error, _} = err), do: err
  defp normalize_response(other), do: {:error, {:invalid_miosa_adapter_response, other}}

  defp fetch_config(config, key) do
    case config[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing :computer_use_miosa #{key}"}
    end
  end

  defp fetch_api_key(config) do
    case api_key(config) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "Missing MIOSA API key. Set MIOSA_API_KEY or :computer_use_miosa[:api_key]"}
    end
  end

  defp api_key(config),
    do: config[:api_key] || Application.get_env(:optimal_system_agent, :miosa_api_key)

  defp base_url(config), do: String.trim_trailing(config[:base_url] || @default_base_url, "/")
  defp get_config, do: Application.get_env(:optimal_system_agent, :computer_use_miosa, [])
  defp present?(value), do: is_binary(value) and value != ""
  defp format_body(body) when is_binary(body), do: body
  defp format_body(body), do: inspect(body)

  defp compact_body(nil), do: %{}

  defp compact_body(params) when is_map(params) do
    params
    |> Map.drop(["action", "__session_id__", "window"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
