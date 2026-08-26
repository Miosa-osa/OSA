defmodule OptimalSystemAgent.Tools.Builtins.Browser do
  @moduledoc """
  Browser automation tool for OSA.

  Two modes:
  1. **Playwright mode** — persistent headless browser via Port (Node.js + Playwright).
     Supports navigate, get_text, get_html, screenshot, click, type, evaluate, close.
  2. **HTTP fallback** — uses :httpc for navigate/get_text/get_html when Playwright
     is unavailable. Always works with zero external dependencies.

  The Playwright browser process is managed by `BrowserServer` (GenServer) which
  starts lazily on first use and auto-closes after 5 minutes of inactivity.
  """

  @behaviour MiosaTools.Behaviour

  alias OptimalSystemAgent.Tools.Builtins.Browser.Server, as: BrowserServer

  @valid_actions ~w(navigate get_text get_html screenshot click type evaluate close)

  @max_body_bytes 50_000
  @timeout_ms 15_000

  @impl true
  def name, do: "browser"

  @impl true
  def description do
    "Control a headless browser for web automation — navigate, get page content, screenshot, " <>
      "interact with elements. Falls back to HTTP fetch when headless browser unavailable."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => @valid_actions,
          "description" =>
            "Action to perform: navigate (go to URL), get_text (extract visible text), " <>
              "get_html (get page HTML), screenshot (capture page as PNG), click (click element), " <>
              "type (fill input), evaluate (run JavaScript), close (close browser)"
        },
        "url" => %{
          "type" => "string",
          "description" => "URL to navigate to (required for navigate action)"
        },
        "selector" => %{
          "type" => "string",
          "description" => "CSS selector for targeting elements (click, type, get_text, get_html)"
        },
        "text" => %{
          "type" => "string",
          "description" => "Text to type into the selected element (required for type action)"
        },
        "script" => %{
          "type" => "string",
          "description" =>
            "JavaScript code to evaluate in the page context (required for evaluate action)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  # Deferred: absent from the default toolbox, discovered mid-turn via
  # `tool_search`. Reason: browser automation is a specialist surface, not a default coding tool.
  #
  # Every schema in the default set is re-sent on EVERY request. Measured
  # across 15 SWE-bench Pro transcripts, this tool was called zero times while
  # costing its schema on all 863 turns.
  @impl true
  def should_defer?, do: true

  def available? do
    # Always available — falls back to HTTP mode when Playwright is absent
    true
  end

  @impl true
  def safety, do: :read_only

  @impl true
  def execute(%{"action" => action} = params) when action in @valid_actions do
    # Validate required params before dispatching to playwright/fallback
    case validate_params(action, params) do
      :ok ->
        if playwright_available?() do
          execute_playwright(action, params)
        else
          execute_fallback(action, params)
        end

      {:error, _} = err ->
        err
    end
  end

  def execute(%{"action" => action}) when is_binary(action) do
    {:error, "Unknown action: #{action}. Valid actions: #{Enum.join(@valid_actions, ", ")}"}
  end

  def execute(_), do: {:error, "Missing required parameter: action"}

  # ---------------------------------------------------------------------------
  # Parameter validation (runs before mode dispatch)
  # ---------------------------------------------------------------------------

  defp validate_params("navigate", params) do
    url = params["url"]

    cond do
      is_nil(url) or url == "" -> {:error, "Missing required parameter: url"}
      not valid_url?(url) -> {:error, "Invalid URL: #{url}"}
      true -> :ok
    end
  end

  defp validate_params("click", params) do
    if is_nil(params["selector"]) or params["selector"] == "",
      do: {:error, "Missing required parameter: selector"},
      else: :ok
  end

  defp validate_params("type", params) do
    cond do
      is_nil(params["selector"]) or params["selector"] == "" ->
        {:error, "Missing required parameter: selector"}

      is_nil(params["text"]) or params["text"] == "" ->
        {:error, "Missing required parameter: text"}

      true ->
        :ok
    end
  end

  defp validate_params("evaluate", params) do
    if is_nil(params["script"]) or params["script"] == "",
      do: {:error, "Missing required parameter: script"},
      else: :ok
  end

  defp validate_params(_action, _params), do: :ok

  # ---------------------------------------------------------------------------
  # Playwright mode — delegate to BrowserServer GenServer
  # ---------------------------------------------------------------------------

  defp execute_playwright(action, params) do
    case ensure_browser_server() do
      :ok -> :ok
      {:error, reason} -> throw({:browser_start_error, reason})
    end

    command =
      %{"action" => action}
      |> maybe_put("url", params["url"])
      |> maybe_put("selector", params["selector"])
      |> maybe_put("text", params["text"])
      |> maybe_put("script", params["script"])

    case BrowserServer.send_command(command) do
      {:ok, result} ->
        {:ok, result}

      {:error, :timeout} ->
        # Retry once with backoff on timeout
        Process.sleep(1_000)

        case BrowserServer.send_command(command) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    {:browser_start_error, reason} -> {:error, reason}
  end

  defp ensure_browser_server do
    case Process.whereis(BrowserServer) do
      nil ->
        try do
          sup = OptimalSystemAgent.SessionSupervisor

          case Process.whereis(sup) do
            nil ->
              {:error, :browser_unavailable}

            _pid ->
              case DynamicSupervisor.start_child(sup, {BrowserServer, []}) do
                {:ok, _pid} -> :ok
                {:error, {:already_started, _pid}} -> :ok
                {:error, reason} -> {:error, "Failed to start browser server: #{inspect(reason)}"}
              end
          end
        catch
          :exit, _ -> {:error, :browser_unavailable}
        end

      _pid ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP fallback mode — uses :httpc for basic web access
  # ---------------------------------------------------------------------------

  defp execute_fallback(action, params) do
    case action do
      "navigate" ->
        fallback_navigate(params)

      "get_text" ->
        fallback_get_text(params)

      "get_html" ->
        fallback_get_html(params)

      "close" ->
        {:ok, "Browser closed (HTTP fallback mode — no persistent browser)"}

      _ ->
        {:error, "Action '#{action}' requires Playwright. Install with: npx playwright install"}
    end
  end

  defp fallback_navigate(%{"url" => url}) when is_binary(url) and url != "" do
    case fetch_url(url) do
      {:ok, body} ->
        title = extract_title(body)
        text = strip_html(body)
        {:ok, "Navigated to #{url} — title: #{title}\n\n#{text}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fallback_navigate(_), do: {:error, "Missing required parameter: url"}

  defp fallback_get_text(params) do
    url = params["url"]
    selector = params["selector"]

    if is_nil(url) or url == "" do
      {:error, "get_text in fallback mode requires a url parameter (no persistent browser state)"}
    else
      case fetch_url(url) do
        {:ok, body} ->
          text =
            if selector do
              extract_by_selector(body, selector) |> strip_html()
            else
              strip_html(body)
            end

          {:ok, text}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fallback_get_html(params) do
    url = params["url"]
    selector = params["selector"]

    if is_nil(url) or url == "" do
      {:error, "get_html in fallback mode requires a url parameter (no persistent browser state)"}
    else
      case fetch_url(url) do
        {:ok, body} ->
          html =
            if selector do
              extract_by_selector(body, selector)
            else
              body
            end
            |> String.slice(0, @max_body_bytes)

          {:ok, html}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP helpers
  # ---------------------------------------------------------------------------

  defp fetch_url(url) do
    if not valid_url?(url) do
      {:error, "Invalid URL: #{url}"}
    else
      case Req.get(url,
             headers: [{"user-agent", "OSA/1.0 Browser Tool"}],
             receive_timeout: @timeout_ms,
             connect_options: [timeout: 5_000]
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body |> to_string() |> String.slice(0, @max_body_bytes)}

        {:ok, %Req.Response{status: status}} ->
          {:error, "HTTP #{status} from #{url}"}

        {:error, reason} ->
          {:error, "Fetch failed: #{inspect(reason)}"}
      end
    end
  end

  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp valid_url?(_), do: false

  # ---------------------------------------------------------------------------
  # HTML helpers
  # ---------------------------------------------------------------------------

  defp strip_html(body) when is_binary(body) do
    body
    |> String.replace(~r/<script[^>]*>[\s\S]*?<\/script>/i, "")
    |> String.replace(~r/<style[^>]*>[\s\S]*?<\/style>/i, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/&quot;/, "\"")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @max_body_bytes)
  end

  defp strip_html(_), do: ""

  defp extract_title(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html) do
      [_, title] -> String.trim(title)
      _ -> "(no title)"
    end
  end

  @doc false
  def extract_by_selector(html, selector) do
    # Best-effort CSS selector extraction for fallback mode.
    # Supports: tag, .class, #id, tag.class, tag#id
    pattern =
      cond do
        String.starts_with?(selector, "#") ->
          id = String.trim_leading(selector, "#")
          ~r/<[^>]*\bid="#{Regex.escape(id)}"[^>]*>[\s\S]*?<\/[^>]+>/i

        String.starts_with?(selector, ".") ->
          class = String.trim_leading(selector, ".")
          ~r/<[^>]*\bclass="[^"]*\b#{Regex.escape(class)}\b[^"]*"[^>]*>[\s\S]*?<\/[^>]+>/i

        String.contains?(selector, "#") ->
          [_tag, id] = String.split(selector, "#", parts: 2)
          ~r/<[^>]*\bid="#{Regex.escape(id)}"[^>]*>[\s\S]*?<\/[^>]+>/i

        String.contains?(selector, ".") ->
          [_tag, class] = String.split(selector, ".", parts: 2)
          ~r/<[^>]*\bclass="[^"]*\b#{Regex.escape(class)}\b[^"]*"[^>]*>[\s\S]*?<\/[^>]+>/i

        true ->
          tag = Regex.escape(selector)
          ~r/<#{tag}[^>]*>[\s\S]*?<\/#{tag}>/i
      end

    case Regex.run(pattern, html) do
      [match | _] -> match
      _ -> ""
    end
  end

  # ---------------------------------------------------------------------------
  # Playwright detection
  # ---------------------------------------------------------------------------

  @doc false
  def playwright_available? do
    case :persistent_term.get({__MODULE__, :playwright_available}, :unchecked) do
      :unchecked ->
        result = check_playwright()
        :persistent_term.put({__MODULE__, :playwright_available}, result)
        result

      cached ->
        cached
    end
  end

  defp check_playwright do
    case System.find_executable("npx") do
      nil ->
        false

      npx ->
        # Check if playwright is installed by trying to get its version
        case System.cmd(npx, ["playwright", "--version"], stderr_to_stdout: true) do
          {output, 0} -> String.contains?(output, ".")
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
